import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../settings/states/settings.dart';
import '../../../videos/models/video.dart';
import '../../../videos/views/components/flow_watch_body.dart';
import '../../../videos/views/components/recommended_videos.dart';
import 'flow_watch_queue_dock.dart';
import 'player_modal_back_handler.dart';
import 'video_queue.dart';

typedef FlowWatchPanel = ({
  String? queueId,
  String title,
  Widget child,
  bool scrollable,
});

/// The supporting pane from Flow's PlayerDetailSideColumn.kt.
class FlowWatchSidePane extends StatelessWidget {
  final Video video;
  final FlowWatchPanel? panel;
  final FlowWatchPanelPresenter onOpen;
  final VoidCallback onClose;

  const FlowWatchSidePane({
    super.key,
    required this.video,
    required this.panel,
    required this.onOpen,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locals = AppLocalizations.of(context)!;
    if (panel case final current?) {
      return PlayerModalBackHandler(
        onBack: onClose,
        child: Column(
          children: [
            ListTile(
              title: Text(current.title),
              trailing: IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonLabel,
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded),
              ),
            ),
            Expanded(
              child: current.scrollable
                  ? SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                      child: current.child,
                    )
                  : current.child,
            ),
          ],
        ),
      );
    }
    final distractionFree = context
        .select((SettingsCubit settings) => settings.state.distractionFreeMode);
    return FlowWatchQueue(
      builder: (context, visible, next) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(0, 12, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (visible) ...[
              FlowWatchQueueDock(
                key: const ValueKey('watch-open-queue'),
                next: next,
                inPane: true,
                onOpen: () =>
                    onOpen(locals.videoQueue, const VideoQueue(), false),
              ),
              const SizedBox(height: 16),
            ],
            if (!distractionFree && video.recommendedVideos.isNotEmpty) ...[
              Text(locals.recommended, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              RecommendedVideos(
                  video: video, watchStyle: true, activeWatch: true),
            ],
          ],
        ),
      ),
    );
  }
}
