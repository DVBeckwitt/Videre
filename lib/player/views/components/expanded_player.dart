import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/video_queue.dart';
import 'package:clipious/music/views/components/music_player.dart';

import '../../../comments/views/components/comments_container.dart';
import '../../../downloads/models/downloaded_video.dart';
import '../../../settings/states/settings.dart';
import '../../../utils.dart';
import '../../../videos/models/video.dart';
import '../../../videos/views/components/info.dart';
import '../../../videos/views/components/flow_watch_body.dart';
import '../../../videos/views/components/recommended_videos.dart';
import '../../models/flow_watch_layout.dart';
import 'flow_watch_queue_dock.dart';
import 'expanded_player_details.dart';
import 'minimize_on_swipe_down.dart';

class ExpandedPlayer extends StatefulWidget {
  final FlowWatchLayout watchLayout;
  final FlowWatchPanelPresenter? onOpenPanel;

  const ExpandedPlayer({
    super.key,
    this.watchLayout = FlowWatchLayout.compact,
    this.onOpenPanel,
  });

  @override
  State<ExpandedPlayer> createState() => _ExpandedPlayerState();
}

class _ExpandedPlayerState extends State<ExpandedPlayer> {
  late final PageController _tabController;

  List<int> _tabOrder(bool distractionFree) =>
      distractionFree ? const [0, 3] : const [0, 1, 2, 3];

  int _visibleIndex(List<int> tabs, int selectedIndex) {
    final index = tabs.indexOf(selectedIndex);
    return index < 0 ? 0 : index;
  }

  @override
  void initState() {
    super.initState();
    final distractionFree =
        context.read<SettingsCubit>().state.distractionFreeMode;
    final selectedIndex =
        context.read<PlayerCubit>().state.selectedFullScreenIndex;
    _tabController = PageController(
      initialPage: _visibleIndex(_tabOrder(distractionFree), selectedIndex),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _syncPage(int index) {
    if (_tabController.hasClients && _tabController.page?.round() == index) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _tabController.hasClients &&
          _tabController.page?.round() != index) {
        _tabController.jumpToPage(index);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    AppLocalizations locals = AppLocalizations.of(context)!;

    var player = context.read<PlayerCubit>();
    var controller = player.state;

    Video? video = controller.currentlyPlaying;
    DownloadedVideo? offlineVid = controller.offlineCurrentlyPlaying;
    var settings = context.watch<SettingsCubit>().state;

    bool isFullScreen =
        controller.fullScreenState == FullScreenState.fullScreen;
    if (!isFullScreen &&
        !controller.isMini &&
        controller.isAudio &&
        (video?.musicMetadata ?? offlineVid?.musicMetadata) != null) {
      return const MusicPlayer();
    }
    if (!isFullScreen &&
        !controller.isMini &&
        !controller.isAudio &&
        video != null &&
        !controller.isPip) {
      final wide = widget.watchLayout == FlowWatchLayout.wide;
      return FlowWatchQueue(
        builder: (context, visible, next) => Stack(
          fit: StackFit.expand,
          children: [
            MinimizeOnSwipeDown(
              key: ValueKey('flow-watch-${video.videoId}'),
              enabled: widget.watchLayout == FlowWatchLayout.compact,
              scrollable: true,
              onSwipeDown: player.showMiniPlayer,
              child: Padding(
                padding: EdgeInsets.only(bottom: visible && !wide ? 96 : 0),
                child: FlowWatchBody(
                  video: video,
                  inPlayer: true,
                  queueDockVisible: visible,
                  showRelated: !wide,
                  relatedGrid: widget.watchLayout == FlowWatchLayout.medium,
                  onOpenPanel: widget.onOpenPanel,
                ),
              ),
            ),
            if (visible && !wide)
              Positioned(
                left: 12,
                right: 12,
                bottom: 16,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 600),
                    child: FlowWatchQueueDock(
                      key: const ValueKey('watch-open-queue'),
                      next: next,
                      onOpen: () => FlowWatchBody.showQueue(context),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    bool distractionFree = settings.distractionFreeMode;
    final tabs = _tabOrder(distractionFree);
    final selectedIndex = context
        .select((PlayerCubit value) => value.state.selectedFullScreenIndex);
    final selectedVisibleIndex = _visibleIndex(tabs, selectedIndex);

    if (video != null) {
      _syncPage(selectedVisibleIndex);
    }

    return !isFullScreen &&
            !controller.isMini &&
            (video != null || offlineVid != null)
        ? Column(children: [
            Expanded(
              child: ExpandedPlayerDetails(
                hasOnlineVideo: video != null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: innerHorizontalPadding),
                  child: video != null
                      ? PageView(
                          controller: _tabController,
                          physics: getDeviceType() == DeviceType.phone &&
                                  (distractionFree ||
                                      !settings.hideCommentsByDefault)
                              ? const BouncingScrollPhysics(
                                  parent: AlwaysScrollableScrollPhysics(),
                                )
                              : const NeverScrollableScrollPhysics(),
                          onPageChanged: (index) {
                            final tab = tabs[index];
                            if (player.state.selectedFullScreenIndex != tab) {
                              player.selectTab(tab);
                            }
                          },
                          children: <Widget>[
                            MinimizeOnSwipeDown(
                              enabled: getDeviceType() == DeviceType.phone &&
                                  !controller.isPip,
                              scrollable: true,
                              onSwipeDown: player.showMiniPlayer,
                              child:
                                  VideoInfo(video: video, loadDislikes: true),
                            ),
                            if (!distractionFree)
                              if (!settings.hideCommentsByDefault ||
                                  selectedIndex == 1)
                                MinimizeOnSwipeDown(
                                  enabled:
                                      getDeviceType() == DeviceType.phone &&
                                          !controller.isPip,
                                  scrollable: true,
                                  onSwipeDown: player.showMiniPlayer,
                                  child: CommentsContainer(
                                    video: video,
                                    key: ValueKey('comms-${video.videoId}'),
                                  ),
                                )
                              else
                                const SizedBox.shrink(),
                            if (!distractionFree)
                              SingleChildScrollView(
                                  child: RecommendedVideos(video: video)),
                            const VideoQueue(),
                          ],
                        )
                      : const VideoQueue(),
                ),
              ),
            ),
            ClipRect(
              child: Align(
                alignment: Alignment.bottomCenter,
                heightFactor: 0.65,
                child: NavigationBar(
                    animationDuration: AppMotion.duration(
                        context, const Duration(milliseconds: 500)),
                    selectedIndex: selectedVisibleIndex,
                    onDestinationSelected: (index) {
                      if (video != null) _tabController.jumpToPage(index);
                      player.selectTab(tabs[index]);
                    },
                    destinations: [
                      NavigationDestination(
                          icon: const Icon(Icons.info), label: locals.info),
                      if (!distractionFree)
                        NavigationDestination(
                            icon: const Icon(Icons.chat_bubble),
                            label: locals.comments),
                      if (!distractionFree)
                        NavigationDestination(
                            icon: const Icon(Icons.schema),
                            label: locals.recommended),
                      NavigationDestination(
                          icon: const Icon(Icons.playlist_play),
                          label: locals.videoQueue)
                    ]),
              ),
            )
          ])
        : const SizedBox.shrink();
  }
}
