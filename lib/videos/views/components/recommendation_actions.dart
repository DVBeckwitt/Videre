import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../player/views/components/player_modal_back_handler.dart';
import '../../../recommendations/recommendation_models.dart';
import '../../models/video.dart';

class VideoRecommendationActions extends StatelessWidget {
  final Video video;
  final String reason;
  final ValueChanged<RecommendationFeedback> onFeedback;
  final bool inPlayer;

  const VideoRecommendationActions(
      {super.key,
      required this.video,
      required this.reason,
      required this.onFeedback,
      this.inPlayer = false});

  Widget _withPlayerBack(Widget child) =>
      inPlayer ? PlayerModalBackHandler(child: child) : child;

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return Row(children: [
      Expanded(
        child: TextButton.icon(
          onPressed: reason.isEmpty
              ? null
              : () => showDialog<void>(
                    context: context,
                    useRootNavigator: false,
                    builder: (context) => _withPlayerBack(AlertDialog(
                      title: Text(locals.flowWhyThis),
                      content: Text(reason),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: Text(locals.ok))
                      ],
                    )),
                  ),
          icon: const Icon(Icons.auto_awesome_outlined, size: 16),
          label: Text(locals.flowWhyThis,
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
      PopupMenuButton<RecommendationFeedback>(
        tooltip: locals.flowForYou,
        onSelected: onFeedback,
        itemBuilder: (context) => [
          PopupMenuItem(
              value: RecommendationFeedback.like,
              child: _withPlayerBack(Text(locals.flowMoreLikeThis))),
          PopupMenuItem(
              value: RecommendationFeedback.notInterested,
              child: Text(locals.flowNotInterested)),
          if (video.authorId?.isNotEmpty == true)
            PopupMenuItem(
                value: RecommendationFeedback.block,
                child: Text(locals.flowBlockChannel)),
        ],
        icon: const Icon(Icons.tune_rounded, size: 18),
      ),
    ]);
  }
}
