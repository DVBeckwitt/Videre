import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../router.dart';
import '../../../subscription_management/view/components/subscribe_button.dart';
import '../../../utils.dart';
import '../../../utils/models/image_object.dart';
import '../../../utils/views/components/channel_avatar.dart';
import '../../../utils/views/components/text_linkified.dart';
import '../../../utils/views/components/thumbnail.dart';
import '../../../videos/models/community_video_filter.dart';
import '../../../videos/models/video.dart';
import '../../../videos/views/components/community_browse.dart';
import '../../../videos/views/components/compact_video.dart';
import '../../../videos/views/components/video_in_list.dart';
import '../../../videos/views/components/video_modal_sheet.dart';
import '../../models/channel.dart';

// Flow ChannelHeaderSection.kt at 565d1f7a: banner, avatar/subscribe row,
// channel identity, then the pinned navigation strip supplied by ChannelScreen.
class ChannelHeader extends StatelessWidget {
  final Channel channel;

  const ChannelHeader({super.key, required this.channel});

  void _showAbout(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    showSafeModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(locals.about, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextLinkified(text: channel.description),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final banners = channel.authorBanners ?? const <ImageObject>[];
    final handle = Uri.tryParse(channel.authorUrl)?.pathSegments.lastOrNull;
    final metadata = [
      if (handle?.startsWith('@') == true) handle!,
      if (channel.subCount > 0)
        locals.nSubscribers(compactCurrency.format(channel.subCount)),
    ].join('  •  ');
    final preview = channel.description.trim();

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: tabletMaxVideoWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (banners.isNotEmpty)
                SizedBox(
                  height: 64,
                  child: Thumbnail(
                    images: banners,
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              if (banners.isNotEmpty) const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                runSpacing: 8,
                spacing: 12,
                children: [
                  ChannelAvatar(
                    name: channel.author,
                    images: channel.authorThumbnails,
                    size: 72,
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SubscribeButton(
                      channelId: channel.authorId,
                      subCount: '',
                      watchStyle: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(channel.author,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              if (metadata.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(metadata,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant)),
                ),
              VideoChannelCommunityLabels(
                  authorId: channel.authorId, authorUrl: channel.authorUrl),
              if (preview.isNotEmpty)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _showAbout(context),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      Expanded(
                        child: Text(preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: colors.onSurfaceVariant)),
                      ),
                      Icon(Icons.chevron_right,
                          color: colors.onSurfaceVariant, size: 18),
                    ]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Flow's ChannelContent shows the featured item above a dense video section.
/// Invidious supplies latest uploads, so the newest visible one leads Home.
class ChannelInfo extends StatelessWidget {
  final Channel channel;

  const ChannelInfo({super.key, required this.channel});

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return CommunityBrowse<Video>(
      items: (channel.latestVideos ?? const [])
          .where((video) => !video.filterHide)
          .toList(),
      match: videoCommunityMatches,
      builder: (context, items, hiddenNotice) => ListView(
        key: const PageStorageKey('channel-home'),
        primary: true,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          if (hiddenNotice != null) hiddenNotice,
          if (items.isNotEmpty)
            VideoListItem(
              key: ValueKey(items.first.videoId),
              video: items.first,
              layout: VideoCardLayout.flowFeed,
              showChannel: false,
              showCommunityLabels: true,
            ),
          if (items.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
              child: Text(locals.latestVideos,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
          for (final item in items.skip(1))
            if (item.filtered)
              VideoListItem(
                key: ValueKey(item.videoId),
                video: item,
                layout: VideoCardLayout.flowFeed,
                showChannel: false,
                showCommunityLabels: true,
              )
            else
              CompactVideo(
                key: ValueKey(item.videoId),
                video: item,
                onTap: item.isUpcoming == true
                    ? null
                    : () =>
                        context.router.push(VideoRoute(videoId: item.videoId)),
                trailing: [
                  if (item.isUpcoming != true)
                    IconButton(
                      tooltip:
                          MaterialLocalizations.of(context).moreButtonTooltip,
                      onPressed: () =>
                          VideoModalSheet.showVideoModalSheet(context, item),
                      icon: const Icon(Icons.more_vert),
                    ),
                ],
              ),
        ],
      ),
    );
  }
}
