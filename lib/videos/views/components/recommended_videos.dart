import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../content_filter/community_filter.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../player/states/player.dart';
import '../../../recommendations/recommendation_service.dart';
import '../../../router.dart';
import '../../models/community_video_filter.dart';
import '../../models/video.dart';
import 'community_browse.dart';
import 'compact_video.dart';
import 'recommendation_actions.dart';
import 'video_in_list.dart';
import 'video_modal_sheet.dart';

/// Re-ranks the selected instance's already-loaded related results locally.
/// This view never discovers content through an additional network provider.
class RecommendedVideos extends StatefulWidget {
  final Video video;
  final bool watchStyle;
  final bool activeWatch;
  final bool watchGrid;

  const RecommendedVideos({
    super.key,
    required this.video,
    this.watchStyle = false,
    this.activeWatch = false,
    this.watchGrid = false,
  });

  @override
  State<RecommendedVideos> createState() => _RecommendedVideosState();
}

class _RecommendedVideosState extends State<RecommendedVideos> {
  late final String _profile = db.profileId;
  late final RecommendationService _engine =
      RecommendationService.forProfile(db, _profile);
  late final AppCubit _app = context.read<AppCubit>();
  late final int _session = _app.state.sessionRevision;
  List<Video>? _ranked;
  Map<String, String> _reasons = {};
  bool _available = false;
  int _revision = 0;

  bool get _current =>
      mounted &&
      _engine.isCurrent &&
      _app.state.profileId == _profile &&
      _app.state.sessionRevision == _session;

  @override
  void initState() {
    super.initState();
    _engine.changes.addListener(_changed);
    unawaited(_rank());
  }

  void _changed() {
    if (!_current) return;
    // Apply newly blocked content immediately, before asynchronous re-ranking.
    setState(() {});
    unawaited(_rank());
  }

  Future<void> _rank() async {
    if (!_current) return;
    final revision = ++_revision;
    try {
      final result = await _engine.rankVideos(
          widget.video.recommendedVideos
              .where((item) => !item.filterHide)
              .toList(),
          surface: 'related');
      if (!_current || revision != _revision || result.cancelled) return;
      setState(() {
        _available = result.available;
        _ranked = result.available
            ? result.items.map((entry) => entry.item).toList()
            : null;
        _reasons = {
          for (final entry in result.items) entry.item.videoId: entry.reason,
        };
      });
    } catch (_) {
      // Optional local ranking must not remove the instance's related results.
      if (_current && revision == _revision) {
        setState(() {
          _ranked = null;
          _available = false;
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant RecommendedVideos oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.videoId != widget.video.videoId ||
        oldWidget.video.recommendedVideos != widget.video.recommendedVideos) {
      _ranked = null;
      _reasons = {};
      _available = false;
      unawaited(_rank());
    }
  }

  @override
  void dispose() {
    _revision++;
    _engine.changes.removeListener(_changed);
    super.dispose();
  }

  Widget? _actions(BuildContext context, Video item, int revision,
      {bool inPlayer = false}) {
    if (!_current || !_available || revision != _revision) return null;
    final reason = _reasons[item.videoId];
    if (reason == null) return null;
    return VideoRecommendationActions(
      video: item,
      reason: reason,
      inPlayer: inPlayer,
      onFeedback: (feedback) async {
        if (!_current || revision != _revision) return;
        try {
          await _engine.feedback(item, RecommendationDomain.video, feedback);
        } catch (_) {
          if (_current && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content:
                    Text(AppLocalizations.of(context)!.couldntFetchVideos)));
          }
        }
      },
    );
  }

  void _openWatchMenu(BuildContext context, Video item) {
    if (!_current) return;
    final revision = _revision;
    final player = context.read<PlayerCubit>().state;
    final inPlayer = player.hasVideo && !player.isMini;
    VideoModalSheet.showVideoModalSheet(
      context,
      item,
      inPlayer: inPlayer,
      recommendationActions: _available && _reasons.containsKey(item.videoId)
          ? (context) =>
              _actions(context, item, revision, inPlayer: inPlayer) ??
              const SizedBox.shrink()
          : null,
    );
  }

  void _openWatchRelated(BuildContext context, Video item) {
    if (!_current || item.isUpcoming == true) return;
    final player = context.read<PlayerCubit>();
    if (widget.activeWatch) {
      if (!player.state.isMini &&
          !player.state.isAudio &&
          !player.state.isClosing &&
          player.state.currentlyPlaying?.videoId == widget.video.videoId) {
        // Flow's PlayerBodySlot opens a related video in the active player.
        player.noteWatchSelection(item.videoId);
        unawaited(player.playVideo([item], audio: false));
      }
      return;
    }
    if (player.state.hasVideo && !player.state.isMini) player.showMiniPlayer();
    AutoRouter.of(context).push(VideoRoute(videoId: item.videoId));
  }

  Widget _watchRelatedList(List<Video> items) => LayoutBuilder(
        builder: (context, constraints) {
          if (widget.watchGrid && constraints.maxWidth >= 500) {
            const gap = 12.0;
            final cardWidth = (constraints.maxWidth - gap) / 2;
            return Wrap(
              spacing: gap,
              runSpacing: 16,
              children: [
                for (final item in items)
                  SizedBox(
                    width: cardWidth,
                    child: VideoListItem(
                      key: ValueKey(item.videoId),
                      video: item,
                      layout: VideoCardLayout.flowFeed,
                      showCommunityLabels: true,
                      openVideoOverride: _openWatchRelated,
                      showVideoModalSheet: _openWatchMenu,
                    ),
                  ),
              ],
            );
          }
          return Column(children: [
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: CompactVideo(
                  key: ValueKey(item.videoId),
                  video: item,
                  onTap: item.isUpcoming == true
                      ? null
                      : () => _openWatchRelated(context, item),
                  trailing: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip:
                          MaterialLocalizations.of(context).moreButtonTooltip,
                      onPressed: () => _openWatchMenu(context, item),
                      icon: const Icon(Icons.more_vert_rounded, size: 20),
                    ),
                  ],
                ),
              ),
          ]);
        },
      );

  @override
  Widget build(BuildContext context) {
    if (!_current) return const SizedBox.shrink();
    final locals = AppLocalizations.of(context)!;
    final visible =
        _engine.eligibleVideos(_ranked ?? widget.video.recommendedVideos);
    // Keep the existing reveal-hidden control for already-loaded related
    // results. Hidden metadata is never sent through the ranker.
    final hidden = _engine
        .eligibleVideos(widget.video.recommendedVideos,
            includeCommunityHidden: true)
        .where((item) => videoCommunityMatches(item)
            .any((match) => match.action == CommunityAction.hide));
    return CommunityBrowse<Video>(
      items: [...visible, ...hidden],
      match: videoCommunityMatches,
      builder: (context, items, hiddenNotice) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!widget.watchStyle)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(locals.recommended,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
          if (hiddenNotice != null) hiddenNotice,
          if (widget.watchStyle)
            _watchRelatedList(items)
          else
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(children: [
                  VideoListItem(
                    key: ValueKey(item.videoId),
                    video: item,
                    showCommunityLabels: true,
                  ),
                  if (_actions(context, item, _revision) case final actions?)
                    actions,
                ]),
              ),
        ],
      ),
    );
  }
}
