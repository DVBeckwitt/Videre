import 'package:flutter/material.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/community_video_filter.dart';
import 'package:clipious/videos/views/components/video_in_list.dart';

import 'community_browse.dart';

class RecommendedVideos extends StatelessWidget {
  final Video video;

  const RecommendedVideos({super.key, required this.video});

  @override
  Widget build(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    var textTheme = Theme.of(context).textTheme;

    ColorScheme colorScheme = Theme.of(context).colorScheme;
    return CommunityBrowse<Video>(
      items: video.recommendedVideos.where((e) => !e.filterHide).toList(),
      match: videoCommunityMatches,
      builder: (context, items, hiddenNotice) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            locals.recommended,
            style:
                textTheme.titleMedium?.copyWith(color: colorScheme.secondary),
          ),
          if (hiddenNotice != null) hiddenNotice,
          for (final item in items)
            VideoListItem(
              key: ValueKey(item.videoId),
              video: item,
              showCommunityLabels: true,
            ),
        ],
      ),
    );
  }
}
