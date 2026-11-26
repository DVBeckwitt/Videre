import 'dart:async';

import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/services/music_sound_controller.dart';
import 'package:clipious/music/views/components/music_replay_gain_controls.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/playback_speed_controls.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

Future<void> showMusicSoundSheet(BuildContext context, PlayerCubit player) =>
    showSafeModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          PlayerModalBackHandler(child: MusicSoundSheet(player: player)),
    );

/// Provides playback speed, pitch, silence skipping, and session-bound EQ.
class MusicSoundSheet extends StatefulWidget {
  final PlayerCubit player;
  const MusicSoundSheet({super.key, required this.player});

  @override
  State<MusicSoundSheet> createState() => _MusicSoundSheetState();
}

class _MusicSoundSheetState extends State<MusicSoundSheet> {
  late final _profile = db.profileId;
  late final _generation = widget.player.backendPlaybackGeneration;

  bool get _supportsAndroidAudio =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _current =>
      !widget.player.isClosed &&
      db.profileId == _profile &&
      widget.player.backendPlaybackGeneration == _generation &&
      widget.player.state.isAudio &&
      !widget.player.state.isClosing;

  @override
  void initState() {
    super.initState();
    // Load controls for the current Music decoder.
    unawaited(widget.player.musicSound.open());
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<PlayerState>(
      stream: widget.player.stream,
      initialData: widget.player.state,
      builder: (context, _) {
        final locals = AppLocalizations.of(context)!;
        final state = widget.player.state;
        final settings = widget.player.settings;
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            key: const ValueKey('music-sound-scroll'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                  child: Text(locals.musicSound,
                      style: Theme.of(context).textTheme.headlineSmall),
                ),
                if (!_current)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(locals.musicSoundSessionChanged),
                  )
                else ...[
                  StreamBuilder<SettingsState>(
                    stream: widget.player.settings.stream,
                    initialData: widget.player.settings.state,
                    builder: (context, snapshot) {
                      final settings = widget.player.settings;
                      final volume = snapshot.data!.musicPlaybackVolume;
                      final percent = NumberFormat.percentPattern(
                          Localizations.localeOf(context).toString());
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(locals.musicPlaybackVolume),
                            Slider(
                              key: const ValueKey('music-playback-volume'),
                              value: volume,
                              divisions: 20,
                              label: percent.format(volume),
                              semanticFormatterCallback: (value) =>
                                  '${locals.musicPlaybackVolume}, ${percent.format(value)}',
                              onChanged: (value) async {
                                if (!_current) return;
                                try {
                                  await settings.setMusicPlaybackVolume(value);
                                } catch (_) {
                                  if (context.mounted && _current) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text(locals.error)));
                                  }
                                }
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  PlaybackSpeedControls(
                    initialSpeed: state.speed,
                    onChanged: (value) {
                      if (_current) widget.player.setSpeed(value);
                    },
                    initialPitchSemitones: state.pitchSemitones,
                    onPitchChanged: _supportsAndroidAudio
                        ? (value) {
                            if (_current) {
                              widget.player.setPitchSemitones(value);
                            }
                          }
                        : null,
                  ),
                  if (_supportsAndroidAudio)
                    BlocSelector<SettingsCubit, SettingsState, bool>(
                      bloc: settings,
                      selector: (state) => state.musicSkipSilence,
                      builder: (context, enabled) => SwitchListTile.adaptive(
                        key: const ValueKey('music-skip-silence'),
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 24),
                        title: Text(locals.musicSkipSilence),
                        subtitle: Text(locals.musicSkipSilenceHint),
                        value: enabled,
                        onChanged: (value) {
                          if (_current) {
                            unawaited(settings.setMusicSkipSilence(value));
                          }
                        },
                      ),
                    ),
                  const Divider(),
                  MusicReplayGainControls(
                      controller: widget.player.musicSound,
                      isCurrent: () => _current),
                  const Divider(),
                  MusicEqualizerControls(
                      controller: widget.player.musicSound,
                      isCurrent: () => _current),
                ],
              ],
            ),
          ),
        );
      });
}

class MusicEqualizerControls extends StatelessWidget {
  final MusicSoundController controller;
  final bool Function() isCurrent;

  const MusicEqualizerControls(
      {super.key, required this.controller, required this.isCurrent});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final locals = AppLocalizations.of(context)!;
        final revision = controller.revision;
        bool current() => isCurrent() && controller.revision == revision;
        final parameters = controller.parameters;
        final output = controller.output;
        final canEdit = controller.available && !controller.busy && current();
        final canSave = controller.supported &&
            !controller.busy &&
            !controller.savingOutputPreset &&
            current();
        final canForget = controller.hasOutputPreset &&
            !controller.busy &&
            !controller.savingOutputPreset &&
            current();
        final canDisable = controller.enabled &&
            !controller.busy &&
            !controller.waiting &&
            current();
        final canReset = parameters != null &&
            !controller.busy &&
            !controller.waiting &&
            current();
        final locale = Localizations.localeOf(context).toString();
        final format = NumberFormat('0.#', locale);
        String frequency(double hertz) => hertz >= 1000
            ? '${format.format(hertz / 1000)} kHz'
            : '${format.format(hertz)} Hz';
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile.adaptive(
                key: const ValueKey('music-equalizer-enabled'),
                contentPadding: EdgeInsets.zero,
                title: Text(locals.musicEqualizer,
                    style: Theme.of(context).textTheme.titleLarge),
                value: controller.enabled,
                onChanged: canEdit || canDisable
                    ? (value) {
                        if (current()) controller.setEnabled(value);
                      }
                    : null,
              ),
              if (output == null)
                Text(locals.musicEqualizerSessionHint)
              else ...[
                Text(locals.musicEqualizerOutput(output.label)),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    controller.outputPresetFailed
                        ? locals.musicOutputPresetFailed
                        : controller.hasOutputPreset
                            ? locals.musicOutputPresetSaved
                            : locals.musicOutputPresetHint,
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonal(
                      key: const ValueKey('music-output-preset-save'),
                      onPressed: canSave
                          ? () {
                              if (current()) {
                                unawaited(controller.saveOutputPreset());
                              }
                            }
                          : null,
                      child: Text(locals.musicOutputPresetSave),
                    ),
                    if (controller.hasOutputPreset)
                      TextButton(
                        key: const ValueKey('music-output-preset-forget'),
                        onPressed: canForget
                            ? () {
                                if (current()) {
                                  unawaited(controller.forgetOutputPreset());
                                }
                              }
                            : null,
                        child: Text(locals.musicOutputPresetForget),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              if (controller.busy || controller.savingOutputPreset)
                const LinearProgressIndicator(
                    key: ValueKey('music-equalizer-loading')),
              if (!controller.supported)
                Text(locals.musicEqualizerUnavailable)
              else if (controller.waiting)
                Text(locals.musicEqualizerWaiting)
              else if (controller.failed) ...[
                Text(locals.musicEqualizerFailed,
                    key: const ValueKey('music-equalizer-failure')),
                Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                        key: const ValueKey('music-equalizer-retry'),
                        onPressed: controller.busy || !current()
                            ? null
                            : () {
                                if (current()) controller.open();
                              },
                        icon: const Icon(Icons.refresh),
                        label: Text(locals.retry))),
              ],
              if (parameters != null) ...[
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton.tonalIcon(
                    key: const ValueKey('music-equalizer-bass'),
                    onPressed: canEdit &&
                            parameters.bands
                                .any((band) => band.frequency <= 250)
                        ? () {
                            if (current()) controller.bass();
                          }
                        : null,
                    icon: const Icon(Icons.speaker_rounded),
                    label: Text(locals.musicBass),
                  ),
                  FilledButton.tonalIcon(
                    key: const ValueKey('music-equalizer-treble'),
                    onPressed: canEdit &&
                            parameters.bands
                                .any((band) => band.frequency >= 4000)
                        ? () {
                            if (current()) controller.treble();
                          }
                        : null,
                    icon: const Icon(Icons.graphic_eq),
                    label: Text(locals.musicTreble),
                  ),
                  TextButton.icon(
                    key: const ValueKey('music-equalizer-reset'),
                    onPressed: canReset
                        ? () {
                            if (current()) controller.flat();
                          }
                        : null,
                    icon: const Icon(Icons.restore),
                    label: Text(locals.musicResetSound),
                  ),
                ]),
                const SizedBox(height: 12),
                for (final band in parameters.bands)
                  _BandControl(
                    key: ValueKey(
                        'music-equalizer-band-${band.index}-$revision'),
                    label: frequency(band.frequency),
                    band: band,
                    parameters: parameters,
                    enabled: canEdit && controller.enabled,
                    onChanged: (gain) async {
                      if (current()) {
                        await controller.setGain(band.index, gain);
                      }
                    },
                  ),
              ],
            ],
          ),
        );
      });
}

class _BandControl extends StatefulWidget {
  final String label;
  final MusicEqualizerBand band;
  final MusicEqualizerParameters parameters;
  final bool enabled;
  final Future<void> Function(double) onChanged;

  const _BandControl(
      {super.key,
      required this.label,
      required this.band,
      required this.parameters,
      required this.enabled,
      required this.onChanged});

  @override
  State<_BandControl> createState() => _BandControlState();
}

class _BandControlState extends State<_BandControl> {
  double? _draft;

  @override
  Widget build(BuildContext context) {
    final parameters = widget.parameters;
    final value = (_draft ?? widget.band.gain)
        .clamp(parameters.minimum, parameters.maximum);
    final gain =
        NumberFormat('+0.#;-0.#', Localizations.localeOf(context).toString())
            .format(value);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('${widget.label} · $gain dB'),
      Semantics(
        label: widget.label,
        child: Slider(
          min: parameters.minimum,
          max: parameters.maximum,
          divisions:
              (parameters.maximum - parameters.minimum).round().clamp(1, 1000),
          value: value,
          label: '$gain dB',
          onChanged:
              widget.enabled ? (value) => setState(() => _draft = value) : null,
          onChangeEnd: widget.enabled
              ? (value) async {
                  await widget.onChanged(value);
                  if (mounted) setState(() => _draft = null);
                }
              : null,
        ),
      ),
    ]);
  }
}
