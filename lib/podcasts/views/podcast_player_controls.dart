import 'dart:math' as math;

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/podcasts/services/podcast_player.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

const podcastBarHeight = 72.0;

/// Uses the existing audio session; navigating away never owns its lifetime.
class PodcastPlaybackBar extends StatelessWidget {
  final PodcastPlayer? controller;
  final EdgeInsetsGeometry padding;

  const PodcastPlaybackBar(
      {super.key, this.controller, this.padding = EdgeInsets.zero});

  @override
  Widget build(BuildContext context) {
    final player = controller ?? context.read<PlayerCubit>().podcasts;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        if (!player.active) return const SizedBox.shrink();
        final locals = AppLocalizations.of(context)!;
        final colors = Theme.of(context).colorScheme;
        final duration = player.duration.inMilliseconds;
        final largeText = MediaQuery.textScalerOf(context).scale(12) > 18;
        return Padding(
          padding: padding,
          child: Material(
            color: colors.surfaceContainer,
            child: SizedBox(
              key: const ValueKey('podcast-playback-bar'),
              height: podcastBarHeight,
              child: Column(children: [
                Expanded(
                  child: Row(children: [
                    Expanded(
                      child: Semantics(
                        button: true,
                        excludeSemantics: true,
                        label:
                            '${locals.musicNowPlaying}, ${player.episode!.title}, ${player.feedTitle}',
                        onTap: () => showPodcastPlayer(context, player),
                        child: InkWell(
                          key: const ValueKey('podcast-player-expand'),
                          excludeFromSemantics: true,
                          onTap: () => showPodcastPlayer(context, player),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: LayoutBuilder(
                                builder: (context, constraints) =>
                                    Row(children: [
                                      if (constraints.maxWidth > 200) ...[
                                        Icon(player.offline
                                            ? Icons.offline_pin_outlined
                                            : Icons.podcasts),
                                        const SizedBox(width: 12),
                                      ],
                                      Expanded(
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Flexible(
                                              child: Text(player.episode!.title,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .titleMedium),
                                            ),
                                            if (!largeText)
                                              Text(
                                                  player.error != null
                                                      ? locals
                                                          .podcastPlaybackError
                                                      : player.offline
                                                          ? '${player.feedTitle} · ${locals.onDevice}'
                                                          : player.feedTitle,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall),
                                          ],
                                        ),
                                      ),
                                    ])),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('podcast-mini-play'),
                      tooltip: player.error != null
                          ? locals.retry
                          : player.playing
                              ? locals.musicPause
                              : locals.musicPlay,
                      onPressed: player.playing ? player.pause : player.resume,
                      icon: Icon(player.error != null
                          ? Icons.refresh
                          : player.playing
                              ? Icons.pause
                              : Icons.play_arrow),
                    ),
                    IconButton(
                      key: const ValueKey('podcast-mini-stop'),
                      tooltip: locals.podcastStop,
                      onPressed: player.stop,
                      icon: const Icon(Icons.close),
                    ),
                  ]),
                ),
                LinearProgressIndicator(
                  minHeight: 2,
                  value: player.loading
                      ? null
                      : duration > 0
                          ? (player.position.inMilliseconds / duration)
                              .clamp(0.0, 1.0)
                          : 0,
                  semanticsLabel: locals.musicPosition,
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

Future<void> showPodcastPlayer(
        BuildContext context, PodcastPlayer controller) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      sheetAnimationStyle: AppMotion.dialogStyle(context),
      builder: (_) => _PodcastPlayerSheet(controller: controller),
    );

class _PodcastPlayerSheet extends StatefulWidget {
  final PodcastPlayer controller;

  const _PodcastPlayerSheet({required this.controller});

  @override
  State<_PodcastPlayerSheet> createState() => _PodcastPlayerSheetState();
}

class _PodcastPlayerSheetState extends State<_PodcastPlayerSheet> {
  double? _seek;
  int? _seekGeneration;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final player = widget.controller;
          final locals = AppLocalizations.of(context)!;
          final generation = player.generation;
          final duration = player.duration.inMilliseconds;
          final maxPosition = math.max(1, duration).toDouble();
          final position = (_seekGeneration == generation && _seek != null
                  ? _seek!
                  : player.position.inMilliseconds.toDouble())
              .clamp(0.0, maxPosition);
          bool current() => player.active && player.generation == generation;
          return ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.9),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                  24, 0, 24, 24 + MediaQuery.paddingOf(context).bottom),
              child: Shortcuts(
                shortcuts: const {
                  SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
                },
                child: FocusTraversalGroup(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [
                      Expanded(
                          child: Text(locals.musicNowPlaying,
                              style: Theme.of(context).textTheme.titleMedium)),
                      const CloseButton(),
                    ]),
                    if (player.active) ...[
                      const Icon(Icons.podcasts, size: 56),
                      const SizedBox(height: 16),
                      Text(player.episode!.title,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 8),
                      Text(player.feedTitle, textAlign: TextAlign.center),
                      if (player.offline)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(locals.onDevice),
                        ),
                      if (player.error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(locals.podcastPlaybackError,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error)),
                        ),
                      const SizedBox(height: 12),
                      if (player.loading) const LinearProgressIndicator(),
                      Semantics(
                        key: ValueKey(('podcast-slider', generation)),
                        label: locals.musicPosition,
                        child: Slider(
                          key: const ValueKey('podcast-player-position'),
                          min: 0,
                          max: maxPosition,
                          value: position,
                          semanticFormatterCallback: (value) =>
                              prettyDurationCustom(
                                  Duration(milliseconds: value.round())),
                          onChanged: duration <= 0 || player.loading
                              ? null
                              : (value) {
                                  if (!current()) return;
                                  setState(() {
                                    _seekGeneration = generation;
                                    _seek = value;
                                  });
                                },
                          onChangeEnd: duration <= 0 || player.loading
                              ? null
                              : (value) {
                                  if (!current()) return;
                                  player.seek(
                                      Duration(milliseconds: value.round()));
                                  setState(() => _seek = null);
                                },
                        ),
                      ),
                      SizedBox(
                        width: double.infinity,
                        child: Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            spacing: 16,
                            children: [
                              Text(prettyDurationCustom(
                                  Duration(milliseconds: position.round()))),
                              Text(prettyDurationCustom(player.duration)),
                            ]),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          IconButton(
                              tooltip: locals.podcastRewind15,
                              onPressed: () => player.seek(Duration(
                                  milliseconds: math.max(0,
                                      player.position.inMilliseconds - 15000))),
                              icon: const Icon(Icons.replay)),
                          IconButton.filled(
                              key: const ValueKey('podcast-player-play'),
                              autofocus: true,
                              tooltip: player.error != null
                                  ? locals.retry
                                  : player.playing
                                      ? locals.musicPause
                                      : locals.musicPlay,
                              iconSize: 40,
                              onPressed:
                                  player.playing ? player.pause : player.resume,
                              icon: Icon(player.error != null
                                  ? Icons.refresh
                                  : player.playing
                                      ? Icons.pause
                                      : Icons.play_arrow)),
                          IconButton(
                              tooltip: locals.podcastForward30,
                              onPressed: () => player.seek(Duration(
                                  milliseconds: duration > 0
                                      ? math.min(
                                          duration,
                                          player.position.inMilliseconds +
                                              30000)
                                      : player.position.inMilliseconds +
                                          30000)),
                              icon: const Icon(Icons.forward_30)),
                          PopupMenuButton<double>(
                            tooltip: locals.playbackSpeed,
                            initialValue: player.speed,
                            onSelected: player.setSpeed,
                            itemBuilder: (_) => [
                              for (final speed in [0.75, 1.0, 1.25, 1.5, 2.0])
                                PopupMenuItem(
                                    value: speed, child: Text('$speed×')),
                            ],
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text('${player.speed}×'),
                            ),
                          ),
                          IconButton(
                              tooltip: locals.podcastStop,
                              onPressed: () async {
                                final route = ModalRoute.of(context);
                                await player.stop();
                                if (context.mounted &&
                                    route?.isCurrent == true) {
                                  Navigator.pop(context);
                                }
                              },
                              icon: const Icon(Icons.stop)),
                        ],
                      ),
                    ],
                  ]),
                ),
              ),
            ),
          );
        },
      );
}
