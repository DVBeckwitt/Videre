import 'package:flutter/material.dart';

import '../../../channels/models/channel.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../subscription_management/view/components/subscribe_button.dart';
import '../../../utils.dart';
import '../../../utils/views/components/channel_avatar.dart';
import '../../../videos/views/components/community_browse.dart';

/// Creator identity and actions from Flow SearchChannelHeroCard.kt at 565d1f7a.
/// Use only the metadata carried in the Invidious search response.
class SearchChannelHeroCard extends StatelessWidget {
  final Channel channel;
  final VoidCallback onOpen;

  const SearchChannelHeroCard(
      {super.key, required this.channel, required this.onOpen});

  void _subscriptions(BuildContext context) {
    showSafeModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(channel.author, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SubscribeButton(
                channelId: channel.authorId, subCount: '', watchStyle: true),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locals = AppLocalizations.of(context)!;
    final handle = Uri.tryParse(channel.authorUrl)?.pathSegments.lastOrNull;
    final metadata = [
      if (handle?.startsWith('@') == true) handle!,
      if (channel.subCount > 0)
        locals.nSubscribers(compactCurrency.format(channel.subCount)),
    ].join('  •  ');
    return Card(
      color: theme.colorScheme.surfaceContainerHigh,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(12),
            child: Row(children: [
              ChannelAvatar(
                  name: channel.author,
                  images: channel.authorThumbnails,
                  size: 56),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(channel.author,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium),
                  if (metadata.isNotEmpty)
                    Text(metadata,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall),
                  VideoChannelCommunityLabels(
                      authorId: channel.authorId,
                      authorUrl: channel.authorUrl,
                      compact: true),
                ],
              )),
            ]),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            OutlinedButton(
                onPressed: onOpen, child: Text(locals.searchOpenChannel)),
            TextButton(
                onPressed: () => _subscriptions(context),
                child: Text(locals.manageSubscriptions)),
          ]),
        ]),
      ),
    );
  }
}
