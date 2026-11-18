import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/video_queue.dart';

import '../../../comments/views/components/comments_container.dart';
import '../../../downloads/models/downloaded_video.dart';
import '../../../settings/states/settings.dart';
import '../../../videos/models/video.dart';
import '../../../videos/views/components/info.dart';
import '../../../videos/views/components/recommended_videos.dart';

class ExpandedSideBar extends StatefulWidget {
  const ExpandedSideBar({super.key});

  @override
  State<ExpandedSideBar> createState() => _ExpandedSideBarState();
}

class _ExpandedSideBarState extends State<ExpandedSideBar>
    with TickerProviderStateMixin {
  TabController? _controller;
  List<int> _tabs = const [];
  bool _syncing = false;

  void _tabChanged() {
    final controller = _controller;
    if (!mounted || _syncing || controller == null) return;
    final player = context.read<PlayerCubit>();
    final selected = _tabs[controller.index];
    if (!player.isClosed && player.state.selectedFullScreenIndex != selected) {
      player.selectTab(selected);
    }
  }

  void _syncTabs(List<int> tabs, int selected) {
    final visible = tabs.indexOf(selected);
    final index = visible < 0 ? 0 : visible;
    if (_controller == null || _tabs.length != tabs.length) {
      _controller?.removeListener(_tabChanged);
      _controller?.dispose();
      _tabs = tabs;
      _controller =
          TabController(length: tabs.length, initialIndex: index, vsync: this)
            ..addListener(_tabChanged);
    } else if (_controller!.index != index) {
      _syncing = true;
      _controller!.index = index;
      _syncing = false;
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_tabChanged);
    _controller?.dispose();
    super.dispose();
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
    var distractionFreeMode = settings.distractionFreeMode;
    return Builder(builder: (context) {
      var selectedIndex = context
          .select((PlayerCubit value) => value.state.selectedFullScreenIndex);
      _syncTabs(distractionFreeMode ? const [0, 3] : const [0, 1, 2, 3],
          selectedIndex);
      return !isFullScreen &&
              !controller.isMini &&
              (video != null || offlineVid != null)
          ? video != null
              ? Column(children: [
                  TabBar(
                      controller: _controller,
                      onTap: (index) => player.selectTab(_tabs[index]),
                      tabs: [
                        Tab(
                          icon: const Icon(Icons.info),
                          text: locals.info,
                        ),
                        if (!distractionFreeMode)
                          Tab(
                            icon: const Icon(Icons.chat_bubble),
                            text: locals.comments,
                          ),
                        if (!distractionFreeMode)
                          Tab(
                            icon: const Icon(Icons.schema),
                            text: locals.recommended,
                          ),
                        Tab(
                          icon: const Icon(Icons.playlist_play),
                          text: locals.videoQueue,
                        )
                      ]),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: innerHorizontalPadding),
                      child: TabBarView(
                          controller: _controller,
                          children: <Widget>[
                            SingleChildScrollView(
                              child: VideoInfo(
                                video: video,
                                titleAndChannelInfo: false,
                              ),
                            ),
                            if (!distractionFreeMode)
                              SingleChildScrollView(
                                child: CommentsContainer(
                                  video: video,
                                  key: ValueKey('comms-${video.videoId}'),
                                ),
                              ),
                            if (!distractionFreeMode)
                              SingleChildScrollView(
                                  child: RecommendedVideos(video: video)),
                            const VideoQueue(),
                          ]),
                    ),
                  )
                ])
              : const SizedBox.shrink()
          : const SizedBox.shrink();
    });
  }
}
