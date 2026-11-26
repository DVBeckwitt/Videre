import 'package:clipious/utils/motion.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/utils/views/components/motion_animation.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/views/screens/add_server.dart';
import 'package:clipious/utils/views/components/device_widget.dart';
import 'package:clipious/utils/views/components/placeholders.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/videos/states/video.dart';
import 'package:clipious/videos/views/components/add_to_playlist_button.dart';
import 'package:clipious/videos/views/components/download_modal_sheet.dart';
import 'package:clipious/videos/views/components/inner_view.dart';
import 'package:clipious/videos/views/components/inner_view_tablet.dart';
import 'package:clipious/videos/views/components/video_share_button.dart';

import '../../../player/states/player.dart';
import '../../../player/views/components/minimize_on_swipe_down.dart';
import '../../../player/views/components/video_retry_notice.dart';
import '../../../utils.dart';
import '../components/backend_status.dart';
import '../components/add_to_queue_button.dart';
import '../components/flow_watch_body.dart';
import '../components/play_button.dart';
import '../components/video_thumbnail.dart';
import '../components/watch_notes_button.dart';

@RoutePage()
class VideoScreen extends StatelessWidget {
  final String videoId;
  final bool? playNow;
  final Duration? startAt;

  const VideoScreen(
      {super.key, required this.videoId, this.playNow, this.startAt});

  void downloadVideo(BuildContext context, VideoState state) {
    var cubit = context.read<VideoCubit>();
    if (state.video != null) {
      DownloadModalSheet.showVideoModalSheet(
        context,
        state.video!,
        onDownloadStarted: (isDownloadStarted) {
          if (isDownloadStarted) {
            cubit.initStreamListener();
          }
        },
        onDownload: cubit.onDownload,
      );
    }
  }

  void openDownloadManager(BuildContext context) {
    var cubit = context.read<VideoCubit>();
    AutoRouter.of(context)
        .push(const DownloadManagerRoute())
        .then((value) => cubit.getDownloadStatus());
  }

  @override
  Widget build(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    ColorScheme colorScheme = Theme.of(context).colorScheme;

    final deviceType = getDeviceType();

    var downloadManager = context.read<DownloadManagerCubit>();

    var player = context.read<PlayerCubit>();
    var settings = context.read<SettingsCubit>();
    var distractionFreeMode = settings.state.distractionFreeMode;
    final hideComments = context
        .select((SettingsCubit cubit) => cubit.state.hideCommentsByDefault);
    return MultiBlocProvider(
      providers: [
        BlocProvider(
            create: (BuildContext context) => VideoCubit(
                VideoState.init(videoId: videoId),
                downloadManager,
                player,
                settings,
                startAt: startAt)),
      ],
      child: BlocConsumer<VideoCubit, VideoState>(
        listenWhen: (previous, current) =>
            (playNow ?? settings.state.autoplayVideoOnLoad) &&
            current.video != null &&
            previous.video == null,
        listener: (context, state) {
          AutoRouter.of(context).maybePop();
          context
              .read<VideoCubit>()
              .playVideo(false, selectedByUser: playNow == true);
        },
        builder: (context, videoState) {
          return OrientationBuilder(builder: (context, orientation) {
            final video = videoState.video;
            final cubit = context.read<VideoCubit>();
            final onStartAt = video == null ||
                    video.liveNow == true ||
                    videoState.loadingVideo ||
                    videoState.error.isNotEmpty
                ? null
                : (Duration position) =>
                    cubit.playVideo(false, startAt: position);
            if (deviceType == DeviceType.phone &&
                orientation == Orientation.portrait &&
                video != null &&
                !videoState.loadingVideo &&
                videoState.error.isEmpty) {
              final restart = context.select((PlayerCubit p) =>
                  p.state.currentlyPlaying?.videoId == video.videoId);
              final downloadInLibrary = videoState.isDownloaded ||
                  videoState.downloading ||
                  videoState.downloadFailed;
              return Scaffold(
                backgroundColor: colorScheme.surface,
                body: SafeArea(
                  child: MinimizeOnSwipeDown(
                    key: const ValueKey('flow-watch-details'),
                    enabled: true,
                    scrollable: true,
                    onSwipeDown: () => AutoRouter.of(context).maybePop(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        VideoThumbnailView(
                          videoId: video.videoId,
                          images: video.deArrowThumbnailUrl == null
                              ? video.videoThumbnails
                              : null,
                          thumbnails: video.deArrowThumbnailUrl == null
                              ? ImageObject.getThumbnailUrlsByPreferredOrder(
                                  video.videoThumbnails)
                              : [video.deArrowThumbnailUrl!],
                          musicThumbnails: video.musicMetadata?.thumbnails,
                          decoration: const BoxDecoration(color: Colors.black),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              PlayButton(
                                watchStyle: true,
                                icon: restart ? Icons.refresh : null,
                                hasAudio: video.liveNow != true,
                                onPressed: restart
                                    ? cubit.restartVideo
                                    : cubit.playVideo,
                              ),
                              Positioned(
                                left: 6,
                                top: 6,
                                child: IconButton(
                                  tooltip: MaterialLocalizations.of(context)
                                      .backButtonTooltip,
                                  onPressed: () =>
                                      AutoRouter.of(context).maybePop(),
                                  style: IconButton.styleFrom(
                                      backgroundColor: Colors.black54,
                                      foregroundColor: Colors.white),
                                  icon: const Icon(Icons.arrow_back_rounded),
                                ),
                              ),
                              Positioned(
                                right: 5,
                                bottom: 3,
                                child: AddToQueueButton(videos: [video]),
                              ),
                            ],
                          ),
                        ),
                        VideoBackendStatus(state: videoState),
                        FlowWatchBody(
                          key: ValueKey(video.videoId),
                          video: video,
                          dislikes: videoState.dislikes,
                          onStartAt: onStartAt,
                          onDownload: downloadInLibrary
                              ? () => openDownloadManager(context)
                              : () => downloadVideo(context, videoState),
                          downloadIcon:
                              videoState.downloadedVideo?.downloadComplete ==
                                          true &&
                                      !videoState.downloadFailed
                                  ? Icons.download_done_rounded
                                  : videoState.downloadFailed
                                      ? Icons.error_outline_rounded
                                      : videoState.downloading
                                          ? Icons.downloading_rounded
                                          : Icons.download_rounded,
                          extraAction: distractionFreeMode
                              ? null
                              : Padding(
                                  padding: const EdgeInsets.only(left: 8),
                                  child: BlocSelector<SettingsCubit,
                                      SettingsState, bool>(
                                    selector: (state) =>
                                        state.playRecommendedNext,
                                    builder: (context, enabled) => FilterChip(
                                      label: Text(locals.addRecommendedToQueue),
                                      selected: enabled,
                                      onSelected:
                                          cubit.togglePlayRecommendedNext,
                                    ),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }
            // we only show the tablet specific view for landscape tablets, phone portrait view is fine here
            var showTabletView = deviceType == DeviceType.tablet &&
                getOrientation() == Orientation.landscape;

            var destinations = List.of(<Widget>[
              NavigationDestination(
                  icon: const Icon(Icons.info), label: locals.info),
              NavigationDestination(
                  icon: const Icon(Icons.chat_bubble), label: locals.comments),
            ], growable: true);

            destinations.add(NavigationDestination(
                icon: const Icon(Icons.schema), label: locals.recommended));

            return AnimatedOpacity(
              duration: AppMotion.fadeDuration(context),
              opacity: videoState.opacity,
              child: AutoTabsRouter.tabBar(
                  animatePageTransition: AppMotion.allowsMovement(context),
                  key: ValueKey(videoState.video),
                  physics: deviceType == DeviceType.phone &&
                          (distractionFreeMode || !hideComments)
                      ? const BouncingScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics(),
                        )
                      : const NeverScrollableScrollPhysics(),
                  routes: [
                    VideoInfoRoute(
                        video: videoState.video,
                        dislikes: videoState.dislikes,
                        titleAndChannelInfo: deviceType == DeviceType.phone),
                    if (!distractionFreeMode)
                      CommentsRoute(video: videoState.video),
                    if (!distractionFreeMode)
                      RecommendedRoute(video: videoState.video)
                  ],
                  builder: (context, child, controller) {
                    final tabsRouter = AutoTabsRouter.of(context);
                    return Scaffold(
                      appBar: AppBar(
                        actions: videoState.loadingVideo ||
                                videoState.video == null
                            ? [WatchNotesButton(videoId: videoId)]
                            : [
                                WatchNotesButton(
                                    videoId: videoId, onStartAt: onStartAt),
                                AnimatedSwitcher(
                                    duration: AppMotion.duration(context),
                                    child: videoState.downloading
                                        ? GestureDetector(
                                            onTap: () =>
                                                openDownloadManager(context),
                                            child: Stack(
                                              alignment: Alignment.center,
                                              children: [
                                                IconButton(
                                                  icon: Icon(
                                                    Icons.add,
                                                    color: colorScheme.surface,
                                                  ),
                                                  onPressed: () {},
                                                ),
                                                SizedBox(
                                                    height: 15,
                                                    width: 15,
                                                    child:
                                                        TweenAnimationBuilder(
                                                            duration: AppMotion
                                                                .duration(
                                                                    context),
                                                            tween: Tween<
                                                                    double>(
                                                                begin: 0,
                                                                end: videoState
                                                                    .downloadProgress),
                                                            builder: (context,
                                                                value, child) {
                                                              return MotionLoadingIndicator(
                                                                  child:
                                                                      CircularProgressIndicator(
                                                                value: videoState
                                                                            .downloadProgress ==
                                                                        0
                                                                    ? null
                                                                    : value,
                                                                strokeWidth: 2,
                                                              ));
                                                            }))
                                              ],
                                            ),
                                          )
                                        : Stack(
                                            children: [
                                              IconButton(
                                                  onPressed: videoState
                                                              .isDownloaded ||
                                                          videoState
                                                              .downloadFailed
                                                      ? () =>
                                                          openDownloadManager(
                                                              context)
                                                      : () => downloadVideo(
                                                          context, videoState),
                                                  icon: videoState.downloadedVideo
                                                                  ?.downloadComplete ==
                                                              true &&
                                                          !videoState
                                                              .downloadFailed
                                                      ? const Icon(
                                                          Icons.download_done)
                                                      : const Icon(
                                                          Icons.download)),
                                              Positioned(
                                                  right: 5,
                                                  top: 5,
                                                  child: videoState
                                                          .downloadFailed
                                                      ? const Icon(
                                                          Icons.error,
                                                          size: 15,
                                                          color: Colors.red,
                                                        )
                                                      : const SizedBox.shrink())
                                            ],
                                          )),
                                Visibility(
                                  visible: videoState.video != null,
                                  child: VideoShareButton(
                                      video: videoState.video!),
                                ),
                                AddToPlayListButton(
                                    videoId: videoState.videoId,
                                    video: videoState.video)
                              ],
                      ),
                      backgroundColor: colorScheme.surface,
                      bottomNavigationBar: showTabletView ||
                              videoState.loadingVideo ||
                              distractionFreeMode
                          ? null
                          : MotionAnimation.fadeIn(
                              child: NavigationBar(
                                animationDuration: AppMotion.duration(
                                    context, const Duration(milliseconds: 500)),
                                onDestinationSelected:
                                    tabsRouter.setActiveIndex,
                                selectedIndex: tabsRouter.activeIndex,
                                destinations: destinations,
                              ),
                            ),
                      body: SafeArea(
                        bottom: false,
                        child: Padding(
                          padding: const EdgeInsets.only(
                              left: innerHorizontalPadding,
                              right: innerHorizontalPadding,
                              top: 8),
                          child: Container(
                            color: colorScheme.surface,
                            width: double.infinity,
                            height: double.infinity,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                VideoBackendStatus(state: videoState),
                                Expanded(
                                    child: AnimatedSwitcher(
                                        duration: AppMotion.duration(context),
                                        child: videoState.error.isNotEmpty
                                            ? Container(
                                                alignment: Alignment.center,
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Text(videoState.error ==
                                                            coulnotLoadVideos
                                                        ? locals
                                                            .couldntLoadVideo
                                                        : videoState.error),
                                                    TextButton.icon(
                                                      onPressed: context
                                                          .read<VideoCubit>()
                                                          .onReady,
                                                      icon: const Icon(
                                                          Icons.refresh),
                                                      label: Text(locals.retry),
                                                    ),
                                                    TextButton.icon(
                                                      onPressed: () =>
                                                          AddServerScreen
                                                              .showConnectionHelp(
                                                                  context,
                                                                  videoId:
                                                                      videoId),
                                                      icon: const Icon(
                                                          Icons.wifi_find),
                                                      label: Text(locals
                                                          .connectionHelp),
                                                    ),
                                                  ],
                                                ),
                                              )
                                            : videoState.loadingVideo
                                                ? showVideoMetadataRetry(
                                                        videoState)
                                                    ? const Center(
                                                        child:
                                                            VideoRetryNotice())
                                                    : const DeviceWidget(
                                                        portraitTabletAsPhone:
                                                            true,
                                                        phone:
                                                            VideoPlaceHolder(),
                                                        tablet:
                                                            TabletVideoPlaceHolder())
                                                : DeviceWidget(
                                                    portraitTabletAsPhone: true,
                                                    phone: VideoInnerView(
                                                      video: videoState.video!,
                                                      playNow: playNow,
                                                      videoController:
                                                          videoState,
                                                      child: child,
                                                    ),
                                                    tablet:
                                                        VideoTabletInnerView(
                                                      video: videoState.video!,
                                                      playNow: playNow,
                                                      videoController:
                                                          videoState,
                                                      tabController: controller,
                                                      child: child,
                                                    ),
                                                  ))),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
            );
          });
        },
      ),
    );
  }
}
