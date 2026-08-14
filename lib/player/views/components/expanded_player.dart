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
import '../../../utils.dart';
import '../../../videos/models/video.dart';
import '../../../videos/views/components/info.dart';
import '../../../videos/views/components/recommended_videos.dart';
import 'mini_player_controls.dart';

class ExpandedPlayer extends StatefulWidget {
  const ExpandedPlayer({super.key});

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
            MiniPlayerControls(
              videoId: video?.videoId ?? offlineVid?.videoId ?? '',
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: innerHorizontalPadding),
                child: video != null
                    ? PageView(
                        controller: _tabController,
                        physics: getDeviceType() == DeviceType.phone
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
                          SingleChildScrollView(
                            child: VideoInfo(
                              video: video,
                            ),
                          ),
                          if (!distractionFree)
                            SingleChildScrollView(
                              child: CommentsContainer(
                                video: video,
                                key: ValueKey('comms-${video.videoId}'),
                              ),
                            ),
                          if (!distractionFree)
                            SingleChildScrollView(
                                child: RecommendedVideos(video: video)),
                          const VideoQueue(),
                        ],
                      )
                    : const VideoQueue(),
              ),
            ),
            ClipRect(
              child: Align(
                alignment: Alignment.bottomCenter,
                heightFactor: 0.65,
                child: NavigationBar(
                    selectedIndex:
                        video != null ? selectedVisibleIndex : selectedIndex,
                    onDestinationSelected: video != null
                        ? (index) {
                            _tabController.jumpToPage(index);
                            player.selectTab(tabs[index]);
                          }
                        : player.selectTab,
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
