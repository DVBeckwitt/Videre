import 'package:flutter/material.dart';

import '../../../content_filter/community_filter.dart';
import '../../../content_filter/community_filter_widgets.dart';
import '../../../channels/models/channel.dart';
import '../../models/video.dart';

List<CommunityMatch> channelCommunityMatches(Channel channel) =>
    communityFilters.match(
        authorId: channel.authorId, authorUrl: channel.authorUrl);

/// Applies local visibility to already-loaded results, independently of cursors.
class CommunityBrowse<T> extends StatefulWidget {
  final List<T> items;
  final List<CommunityMatch> Function(T item)? match;
  final bool compactNotice;
  final Widget Function(BuildContext context, List<T> items, Widget? notice)
      builder;

  const CommunityBrowse({
    super.key,
    required this.items,
    required this.match,
    required this.builder,
    this.compactNotice = false,
  });

  @override
  State<CommunityBrowse<T>> createState() => _CommunityBrowseState<T>();
}

class _CommunityBrowseState<T> extends State<CommunityBrowse<T>> {
  bool _showHidden = false;

  @override
  Widget build(BuildContext context) {
    final match = widget.match;
    if (match == null) return widget.builder(context, widget.items, null);
    return ListenableBuilder(
      listenable: communityFilters.changes,
      builder: (context, _) {
        final visible = widget.items
            .where((item) => !match(item)
                .any((entry) => entry.action == CommunityAction.hide))
            .toList();
        final hidden = widget.items.length - visible.length;
        return widget.builder(
          context,
          _showHidden ? widget.items : visible,
          hidden == 0
              ? null
              : CommunityHiddenNotice(
                  count: hidden,
                  showing: _showHidden,
                  onToggle: () => setState(() => _showHidden = !_showHidden),
                  compact: widget.compactNotice,
                ),
        );
      },
    );
  }
}

class VideoChannelCommunityLabels extends StatelessWidget {
  final String? authorId;
  final String? authorUrl;
  final bool compact;
  final bool interactive;

  const VideoChannelCommunityLabels({
    super.key,
    required this.authorId,
    required this.authorUrl,
    this.compact = false,
    this.interactive = true,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: communityFilters.changes,
        builder: (context, _) => CommunityMatchLabels(
          matches:
              communityFilters.match(authorId: authorId, authorUrl: authorUrl),
          compact: compact,
          interactive: interactive,
        ),
      );
}

Widget labelVideoThumbnail(Video video, Widget thumbnail,
    {bool focusable = true}) {
  return Stack(
    fit: StackFit.passthrough,
    children: [
      thumbnail,
      PositionedDirectional(
        top: 4,
        start: 4,
        end: 4,
        child: Align(
          alignment: AlignmentDirectional.topEnd,
          child: VideoChannelCommunityLabels(
            authorId: video.authorId,
            authorUrl: video.authorUrl,
            compact: true,
            interactive: focusable,
          ),
        ),
      ),
    ],
  );
}
