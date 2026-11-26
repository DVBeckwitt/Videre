import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:clipious/main.dart';
import 'package:clipious/subscription_management/view/components/subscription_feed_groups.dart';
import 'package:clipious/utils/views/tv/components/tv_horizontal_item_list.dart';

import 'video_list.dart';

class Subscriptions extends StatelessWidget {
  final void Function(Video video, int index, bool focus)? onItemFocus;
  final bool nestedScroll;

  const Subscriptions({super.key, this.onItemFocus, this.nestedScroll = false});

  @override
  Widget build(BuildContext context) {
    var colorScheme = Theme.of(context).colorScheme;
    return Container(
      color: colorScheme.surface,
      child: SubscriptionFeedGroups(builder: (context, feed, filters) {
        return Column(
          mainAxisSize: isTv ? MainAxisSize.min : MainAxisSize.max,
          children: [
            filters,
            if (isTv)
              TvHorizontalVideoList(
                paginatedVideoList: feed,
                onItemFocus: onItemFocus,
              )
            else
              Expanded(
                child: VideoList(
                  nestedScroll: nestedScroll,
                  communityBrowse: true,
                  animateDownload: true,
                  paginatedVideoList: feed,
                ),
              ),
          ],
        );
      }),
    );
  }
}
