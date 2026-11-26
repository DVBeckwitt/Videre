import 'dart:async';

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/replay_gain.dart';
import 'package:clipious/music/services/music_sound_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// Profile-level Music gain controls shared by Settings and Now Playing.
class MusicReplayGainControls extends StatefulWidget {
  final MusicSoundController controller;
  final bool Function() isCurrent;

  final FocusNode? replayGainFocusNode;
  final FocusNode? preampFocusNode;
  final FocusNode? untaggedPreampFocusNode;

  const MusicReplayGainControls({
    super.key,
    required this.controller,
    required this.isCurrent,
    this.replayGainFocusNode,
    this.preampFocusNode,
    this.untaggedPreampFocusNode,
  });

  @override
  State<MusicReplayGainControls> createState() =>
      _MusicReplayGainControlsState();
}

class _MusicReplayGainControlsState extends State<MusicReplayGainControls> {
  // Keep the arrival nodes on the same controls as their values change.
  late final _arrivalMode = widget.controller.replayGainMode;
  late final _arrivalPreampIncrease =
      widget.controller.musicTaggedPreampDb <= minimumMusicPreampDb;
  late final _arrivalUntaggedPreampIncrease =
      widget.controller.musicUntaggedPreampDb <= minimumMusicPreampDb;

  bool _saving = false;
  bool _failed = false;

  Future<void> _save(int revision, Future<void> Function() write) async {
    if (!widget.isCurrent() ||
        widget.controller.revision != revision ||
        _saving) {
      return;
    }
    _saving = true;
    if (_failed) setState(() => _failed = false);
    try {
      await write();
    } catch (_) {
      if (mounted &&
          widget.isCurrent() &&
          widget.controller.revision == revision) {
        setState(() => _failed = true);
      }
    } finally {
      _saving = false;
    }
  }

  Widget _preampControl({
    required int revision,
    required String keyPrefix,
    required String label,
    required String decreaseLabel,
    required String increaseLabel,
    required double preampDb,
    required Future<void> Function(double) setPreampDb,
    required bool arrivalIncreases,
    FocusNode? arrivalFocusNode,
  }) {
    final locals = AppLocalizations.of(context)!;
    final number = NumberFormat(
      '0.#',
      Localizations.localeOf(context).toString(),
    ).format(preampDb);
    final gain = locals.musicPreampValue(preampDb > 0 ? '+$number' : number);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleMedium),
        Row(
          children: [
            IconButton.filledTonal(
              key: ValueKey('$keyPrefix-decrease'),
              tooltip: decreaseLabel,
              focusNode: arrivalIncreases ? null : arrivalFocusNode,
              onPressed: preampDb > minimumMusicPreampDb
                  ? () => _save(revision, () => setPreampDb(preampDb - 1))
                  : null,
              icon: const Icon(Icons.remove),
            ),
            Expanded(
              child: Semantics(
                label: label,
                value: gain,
                liveRegion: true,
                excludeSemantics: true,
                child: Text(gain, textAlign: TextAlign.center),
              ),
            ),
            IconButton.filledTonal(
              key: ValueKey('$keyPrefix-increase'),
              tooltip: increaseLabel,
              focusNode: arrivalIncreases ? arrivalFocusNode : null,
              onPressed: preampDb < maximumMusicPreampDb
                  ? () => _save(revision, () => setPreampDb(preampDb + 1))
                  : null,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final locals = AppLocalizations.of(context)!;
          final controller = widget.controller;
          final revision = controller.revision;
          final modeLabels = {
            ReplayGainMode.off: locals.musicReplayGainOff,
            ReplayGainMode.track: locals.musicReplayGainTrack,
            ReplayGainMode.album: locals.musicReplayGainAlbum,
            ReplayGainMode.contextual: locals.musicReplayGainContextual,
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
                            focusNode: _arrivalMode == mode
                                ? widget.replayGainFocusNode
                                : null,
                            onSelected: (selected) {
                              if (selected) {
                                unawaited(
                                  _save(revision,
                                      () => controller.setReplayGainMode(mode)),
                                );
                              }
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _preampControl(
                      revision: revision,
                      keyPrefix: 'music-tagged-preamp',
                      label: locals.musicTaggedPreamp,
                      decreaseLabel: locals.musicTaggedPreampDecrease,
                      increaseLabel: locals.musicTaggedPreampIncrease,
                      preampDb: controller.musicTaggedPreampDb,
                      setPreampDb: controller.setMusicTaggedPreampDb,
                      arrivalIncreases: _arrivalPreampIncrease,
                      arrivalFocusNode: widget.preampFocusNode,
                    ),
                    const SizedBox(height: 12),
                    _preampControl(
                      revision: revision,
                      keyPrefix: 'music-untagged-preamp',
                      label: locals.musicUntaggedPreamp,
                      decreaseLabel: locals.musicUntaggedPreampDecrease,
                      increaseLabel: locals.musicUntaggedPreampIncrease,
                      preampDb: controller.musicUntaggedPreampDb,
                      setPreampDb: controller.setMusicUntaggedPreampDb,
                      arrivalIncreases: _arrivalUntaggedPreampIncrease,
                      arrivalFocusNode: widget.untaggedPreampFocusNode,
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
