import 'package:clipious/channels/models/channel.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/utils/views/components/channel_avatar.dart';
import 'package:flutter/material.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/utils/views/components/text_linkified.dart';

import '../../../subscription_management/view/components/subscribe_button.dart';
import '../../../utils/models/image_object.dart';
import '../../../videos/models/community_video_filter.dart';
import '../../../videos/models/video.dart';
import '../../../videos/views/components/video_in_list.dart';
import '../../../videos/views/components/community_browse.dart';

class ChannelInfo extends StatelessWidget {
  final Channel channel;

  const ChannelInfo({super.key, required this.channel});

  @override
  Widget build(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    ColorScheme colors = Theme.of(context).colorScheme;
    var textTheme = Theme.of(context).textTheme;

    final deviceType = getDeviceType();
    List<Widget> widgets = [
      Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ChannelAvatar(
              name: channel.author, images: channel.authorThumbnails, size: 50),
          const SizedBox(
            width: 8,
          ),
          Text(
            channel.author,
            style: textTheme.titleLarge?.copyWith(color: colors.primary),
          ),
        ],
      ),
      VideoChannelCommunityLabels(
        authorId: channel.authorId,
        authorUrl: channel.authorUrl,
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0),
        child: Row(
          children: [
            SubscribeButton(
                channelId: channel.authorId,
                subCount: compactCurrency.format(channel.subCount)),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0),
        child: TextLinkified(text: channel.description),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0),
        child: Text(
          locals.latestVideos,
          style: textTheme.titleMedium?.copyWith(color: colors.secondary),
        ),
      ),
    ];

    widgets.add(CommunityBrowse<Video>(
      items: channel.latestVideos ?? const [],
      match: videoCommunityMatches,
      builder: (context, items, hiddenNotice) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hiddenNotice != null) hiddenNotice,
          GridView.count(
            crossAxisCount: getGridCount(context),
            padding: const EdgeInsets.all(4),
            crossAxisSpacing: 5,
            physics: const NeverScrollableScrollPhysics(),
            shrinkWrap: true,
            mainAxisSpacing: 5,
            childAspectRatio: getGridAspectRatio(context),
            children: [
              for (final item in items)
                VideoListItem(
                  key: ValueKey(item.videoId),
                  video: item,
                  showCommunityLabels: true,
                ),
            ],
          ),
        ],
      ),
    ));

    final bannerUrl = ImageObject.getBestThumbnail(channel.authorBanners)?.url;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (bannerUrl != null)
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: innerHorizontalPadding),
              child: SizedBox(
                height: deviceType == DeviceType.phone ? 100 : 230,
                child: Thumbnail(
                    images: channel.authorBanners,
                    width: double.infinity,
                    thumbnails: [bannerUrl],
                    decoration: BoxDecoration(
                        color: colors.secondaryContainer,
                        borderRadius: BorderRadius.circular(10))),
              ),
            ),
          const SizedBox(
            height: 10,
          ),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: innerHorizontalPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: widgets,
            ),
          )
        ],
      ),
    );
  }
}
