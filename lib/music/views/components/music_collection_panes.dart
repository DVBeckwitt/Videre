import 'dart:ui' show SemanticsRole;

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/utils.dart' show DeviceType, getDeviceType;
import 'package:flutter/material.dart';

/// Displays the collection information beside its tracks on wide tablets.
class MusicCollectionPanes extends StatelessWidget {
  const MusicCollectionPanes({
    super.key,
    required this.details,
    required this.buildTracks,
    this.detailsKey,
  });

  final Widget details;
  final Widget Function(BuildContext context, bool split) buildTracks;
  final Key? detailsKey;

  /// Whether the available width after insets can show both panes.
  static bool shouldSplit(double width) =>
      !isTv &&
      getDeviceType() == DeviceType.tablet &&
      width.isFinite &&
      width >= 720;

  @override
  Widget build(BuildContext context) {
    final labels = AppLocalizations.of(context)!;
    return LayoutBuilder(builder: (context, constraints) {
      final split = shouldSplit(constraints.maxWidth);
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (split) ...[
          SizedBox(
            width: (constraints.maxWidth * 0.35).clamp(248.0, 380.0).toDouble(),
            child: Semantics(
              key: const ValueKey('music-collection-details-pane'),
              container: true,
              explicitChildNodes: true,
              role: SemanticsRole.region,
              label: labels.musicCollectionDetailsPane,
              child: SingleChildScrollView(
                key: detailsKey,
                primary: false,
                child: details,
              ),
            ),
          ),
          const VerticalDivider(width: 1),
        ],
        // Keep the track viewport and its focus mounted when the details pane
        // appears or disappears as the available width changes.
        Expanded(
          key: const ValueKey('music-collection-tracks-slot'),
          child: Semantics(
            key: const ValueKey('music-collection-tracks-pane'),
            container: split,
            explicitChildNodes: split,
            role: split ? SemanticsRole.region : null,
            label: split ? labels.musicCollectionTracksPane : null,
            child: buildTracks(context, split),
          ),
        ),
      ]);
    });
  }
}
