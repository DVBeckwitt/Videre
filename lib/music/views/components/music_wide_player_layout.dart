import 'dart:ui' show SemanticsRole;

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

/// Two persistent panes for expanded Music on wide touch screens.
class MusicWidePlayerLayout extends StatelessWidget {
  const MusicWidePlayerLayout({
    super.key,
    required this.nowPlaying,
    required this.queue,
  });

  final Widget nowPlaying;
  final Widget queue;

  @override
  Widget build(BuildContext context) {
    final labels = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          role: SemanticsRole.region,
          label: labels.musicNowPlaying,
          child: nowPlaying,
        ),
      ),
      Expanded(
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          role: SemanticsRole.complementary,
          label: labels.musicQueue,
          child: Material(
            color: colors.surfaceContainerHigh,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 64),
                child: Center(
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(labels.musicQueue,
                        textAlign: TextAlign.center,
                        semanticsLabel: '',
                        style: theme.textTheme.titleMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
              Expanded(child: queue),
            ]),
          ),
        ),
      ),
    ]);
  }
}
