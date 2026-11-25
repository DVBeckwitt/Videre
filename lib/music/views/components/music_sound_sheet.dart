import 'dart:async';

import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/replay_gain.dart';
import 'package:clipious/music/services/music_sound_controller.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/playback_speed_controls.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

Future<void> showMusicSoundSheet(BuildContext context, PlayerCubit player) =>
    showSafeModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          PlayerModalBackHandler(child: MusicSoundSheet(player: player)),
    );

/// Shares Videre's speed/pitch controls and adds optional session-bound EQ.
class MusicSoundSheet extends StatefulWidget {
  final PlayerCubit player;
  const MusicSoundSheet({super.key, required this.player});

  @override
  State<MusicSoundSheet> createState() => _MusicSoundSheetState();
}

class _MusicSoundSheetState extends State<MusicSoundSheet> {
  late final _profile = db.profileId;
  late final _generation = widget.player.backendPlaybackGeneration;

  bool get _current =>
      !widget.player.isClosed &&
      db.profileId == _profile &&
      widget.player.backendPlaybackGeneration == _generation &&
      widget.player.state.isAudio &&
      !widget.player.state.isClosing;

  @override
  void initState() {
    super.initState();
    // Opening the sheet is the first operation that may allocate an EQ effect.
    unawaited(widget.player.musicSound.open());
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<PlayerState>(
      stream: widget.player.stream,
      initialData: widget.player.state,
      builder: (context, _) {
        final locals = AppLocalizations.of(context)!;
        final state = widget.player.state;
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
                    onPitchChanged: !kIsWeb &&
                            defaultTargetPlatform == TargetPlatform.android
                        ? (value) {
                            if (_current) {
                              widget.player.setPitchSemitones(value);
                            }
                          }
                        : null,
                  ),
                  const Divider(),
                  _MusicReplayGainControls(
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

class _MusicReplayGainControls extends StatefulWidget {
  final MusicSoundController controller;
  final bool Function() isCurrent;

  const _MusicReplayGainControls({
    required this.controller,
    required this.isCurrent,
  });

  @override
  State<_MusicReplayGainControls> createState() =>
      _MusicReplayGainControlsState();
}

class _MusicReplayGainControlsState extends State<_MusicReplayGainControls> {
  bool _saving = false;
  bool _failed = false;

  Future<void> _save(Future<void> Function() write) async {
    if (!widget.isCurrent() || _saving) return;
    _saving = true;
    if (_failed) setState(() => _failed = false);
    try {
      await write();
    } catch (_) {
      if (mounted && widget.isCurrent()) setState(() => _failed = true);
    } finally {
      _saving = false;
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final locals = AppLocalizations.of(context)!;
          final controller = widget.controller;
          final preampDb = controller.musicPreampDb;
          final number = NumberFormat(
            '0.#',
            Localizations.localeOf(context).toString(),
          ).format(preampDb);
          final gain =
              locals.musicPreampValue(preampDb > 0 ? '+$number' : number);
          final modeLabels = {
            ReplayGainMode.off: locals.musicReplayGainOff,
            ReplayGainMode.track: locals.musicReplayGainTrack,
            ReplayGainMode.album: locals.musicReplayGainAlbum,
          };
          return Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    locals.musicReplayGain,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  if (!controller.replayGainSupported)
                    Text(locals.musicReplayGainUnavailable)
                  else ...[
                    Text(locals.musicReplayGainHelp),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final MapEntry(key: mode, value: label)
                            in modeLabels.entries)
                          ChoiceChip(
                            key: ValueKey('music-replaygain-${mode.name}'),
                            label: Text(label),
                            selected: controller.replayGainMode == mode,
                            onSelected: (selected) {
                              if (selected) {
                                unawaited(
                                  _save(
                                      () => controller.setReplayGainMode(mode)),
                                );
                              }
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      locals.musicPreamp,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Row(
                      children: [
                        IconButton.filledTonal(
                          key: const ValueKey('music-preamp-decrease'),
                          tooltip: locals.musicPreampDecrease,
                          onPressed: preampDb > minimumMusicPreampDb
                              ? () => _save(
                                    () => controller
                                        .setMusicPreampDb(preampDb - 1),
                                  )
                              : null,
                          icon: const Icon(Icons.remove),
                        ),
                        Expanded(
                          child: Semantics(
                            label: locals.musicPreamp,
                            value: gain,
                            liveRegion: true,
                            excludeSemantics: true,
                            child: Text(gain, textAlign: TextAlign.center),
                          ),
                        ),
                        IconButton.filledTonal(
                          key: const ValueKey('music-preamp-increase'),
                          tooltip: locals.musicPreampIncrease,
                          onPressed: preampDb < maximumMusicPreampDb
                              ? () => _save(
                                    () => controller
                                        .setMusicPreampDb(preampDb + 1),
                                  )
                              : null,
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                    if (_failed)
                      Semantics(
                        liveRegion: true,
                        child: Text(locals.musicReplayGainSaveFailed),
                      ),
                  ],
                ],
              ),
            ),
          );
        },
      );
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
        final canEdit = controller.available && !controller.busy && current();
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
              Text(locals.musicEqualizerSessionHint),
              const SizedBox(height: 12),
              if (controller.busy)
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
