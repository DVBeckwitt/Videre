import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/audio_player.dart';
import 'package:clipious/player/views/components/expanded_player.dart';
import 'package:clipious/player/views/components/mini_player.dart';
import 'package:clipious/player/views/components/video_player.dart';
import 'package:clipious/player/views/tablet/expanded_player.dart';
import 'package:clipious/player/views/tablet/expanded_side_bar.dart';
import 'package:clipious/utils/views/components/conditional_wrap.dart';
import 'package:clipious/utils/views/components/device_widget.dart';
import 'package:clipious/videos/views/components/add_to_playlist_button.dart';
import 'package:clipious/videos/views/components/video_transcript_button.dart';

import '../../../utils.dart';
import '../../../videos/models/video.dart';
import '../../../videos/views/components/video_share_button.dart';

const double tabletMiniPlayerFraction = 0.25;

class Player extends StatelessWidget {
  final double maxHeight;

  const Player(this.maxHeight, {super.key});

  @override
  Widget build(BuildContext context) {
    var themeData = Theme.of(context);
    ColorScheme colors = themeData.colorScheme;
    AppLocalizations locals = AppLocalizations.of(context)!;
    return Builder(
      builder: (context) {
        var cubit = context.read<PlayerCubit>();

        final bool showPlayer =
            context.select((PlayerCubit value) => value.state.hasVideo);
        final double? top =
            context.select((PlayerCubit value) => value.state.top);
        final bool isMini =
            context.select((PlayerCubit value) => value.state.isMini);
        final bool isPip =
            context.select((PlayerCubit value) => value.state.isPip);
        final bool isHidden =
            context.select((PlayerCubit value) => value.state.isHidden);
        final bool isAudio =
            context.select((PlayerCubit value) => value.state.isAudio);
        final bool isDragging =
            context.select((PlayerCubit value) => value.state.isDragging);
        final bool isClosing =
            context.select((PlayerCubit value) => value.state.isClosing);
        final Video? currentlyPlaying =
            context.select((PlayerCubit value) => value.state.currentlyPlaying);
        final FullScreenState fullScreen =
            context.select((PlayerCubit value) => value.state.fullScreenState);
        final bool isFullScreen = fullScreen == FullScreenState.fullScreen;
        final double aspectRatio =
            context.select((PlayerCubit value) => value.state.aspectRatio);
        final deviceType = getDeviceType();
        final orientation =
            context.select((PlayerCubit value) => value.state.orientation);
        final canSwipeDownToMinimize = deviceType == DeviceType.phone &&
            !isAudio &&
            !isMini &&
            !isPip &&
            !isFullScreen;

        final playerHorizontalPosition = orientation == Orientation.landscape &&
                isMini &&
                deviceType == DeviceType.tablet
            ? getFractionOfAvailableSpace(context, tabletMiniPlayerFraction)
            : const Size(0, 0);

        Widget videoPlayer = showPlayer
            ? BlocBuilder<PlayerCubit, PlayerState>(
                buildWhen: (previous, current) =>
                    previous.isAudio != current.isAudio ||
                    previous.currentlyPlaying != current.currentlyPlaying ||
                    previous.offlineCurrentlyPlaying !=
                        current.offlineCurrentlyPlaying,
                builder: (context, state) {
                  return AspectRatio(
                    aspectRatio: isFullScreen ? aspectRatio : 16 / 9,
                    child: state.isAudio
                        ? AudioPlayer(
                            key: const ValueKey('audio-player'),
                            video:
                                state.isAudio ? state.currentlyPlaying : null,
                            offlineVideo: state.isAudio
                                ? state.offlineCurrentlyPlaying
                                : null,
                            miniPlayer: false,
                          )
                        : VideoPlayer(
                            key: const ValueKey('player'),
                            video:
                                !state.isAudio ? state.currentlyPlaying : null,
                            offlineVideo: !state.isAudio
                                ? state.offlineCurrentlyPlaying
                                : null,
                            miniPlayer: false,
                            startAt: state.startAt,
                          ),
                  );
                })
            : const SizedBox.shrink();

        return AnimatedPositioned(
          left: playerHorizontalPosition.width,
          right: playerHorizontalPosition.width,
          top: top,
          bottom: isClosing
              ? -targetHeight
              : isFullScreen
                  ? 0
                  : isMini && isDragging && top != null
                      ? maxHeight - top - targetHeight
                      : cubit.getBottom,
          duration: isDragging ? Duration.zero : animationDuration,
          curve: Curves.easeInOutQuad,
          child: AnimatedOpacity(
            duration: animationDuration,
            opacity: isClosing ? 0 : 1,
            child: AnimatedScale(
              scale: (isMini && isDragging) ? 0.8 : 1,
              duration: animationDuration,
              curve: Curves.easeInOutQuad,
              child: Material(
                elevation: 0,
                child: showPlayer
                    ? GestureDetector(
                        child: SafeArea(
                          bottom: !isDragging,
                          top: false,
                          left: !isFullScreen,
                          right: !isFullScreen,
                          child: AnimatedContainer(
                            duration: animationDuration,
                            color: colors.surface,
                            padding: EdgeInsets.symmetric(
                                horizontal: isMini && !isDragging ? 7 : 0),
                            child: ClipRRect(
                              borderRadius: isMini
                                  ? BorderRadius.circular(10)
                                  : BorderRadius.circular(0),
                              child: AnimatedContainer(
                                duration: animationDuration,
                                decoration: BoxDecoration(
                                  color: isFullScreen
                                      ? Colors.black
                                      : isMini
                                          ? colors.secondaryContainer
                                          : colors.surface,
                                ),
                                child: Column(
                                  mainAxisSize: isMini
                                      ? MainAxisSize.min
                                      : MainAxisSize.max,
                                  children: [
                                    isMini || isPip || isFullScreen
                                        ? const SizedBox.shrink()
                                        : AppBar(
                                            title: Text(locals.videoPlayer),
                                            leading: IconButton(
                                              icon:
                                                  const Icon(Icons.expand_more),
                                              onPressed: cubit.showMiniPlayer,
                                            ),
                                            actions: isHidden ||
                                                    currentlyPlaying == null
                                                ? []
                                                : [
                                                    VideoShareButton(
                                                      video: currentlyPlaying,
                                                      showTimestampOption: true,
                                                    ),
                                                    if (currentlyPlaying
                                                        .captions.isNotEmpty)
                                                      VideoTranscriptButton(
                                                        video: currentlyPlaying,
                                                      ),
                                                    AddToPlayListButton(
                                                        key: ValueKey(
                                                            currentlyPlaying),
                                                        videoId:
                                                            currentlyPlaying
                                                                .videoId)
                                                  ],
                                          ),
                                    Flexible(
                                      fit: isMini
                                          ? FlexFit.loose
                                          : FlexFit.tight,
                                      child: AnimatedContainer(
                                        // this is just to animate the transition to mini player
                                        constraints: BoxConstraints(
                                          maxHeight: isFullScreen
                                              ? MediaQuery.of(context)
                                                  .size
                                                  .height
                                              : isMini
                                                  ? targetHeight
                                                  : 500,
                                        ),
                                        duration: animationDuration,
                                        child: Row(
                                          mainAxisAlignment: isMini
                                              ? MainAxisAlignment.spaceBetween
                                              : MainAxisAlignment.center,
                                          children: [
                                            Flexible(
                                                fit: isMini
                                                    ? FlexFit.loose
                                                    : FlexFit.tight,
                                                flex: deviceType ==
                                                        DeviceType.tablet
                                                    ? 2
                                                    : 1,
                                                child: Column(
                                                  mainAxisSize: isMini
                                                      ? MainAxisSize.min
                                                      : MainAxisSize.max,
                                                  mainAxisAlignment:
                                                      isFullScreen
                                                          ? MainAxisAlignment
                                                              .center
                                                          : MainAxisAlignment
                                                              .start,
                                                  crossAxisAlignment: isMini
                                                      ? CrossAxisAlignment.start
                                                      : CrossAxisAlignment
                                                          .center,
                                                  children: [
                                                    Container(
                                                        constraints: BoxConstraints(
                                                            maxHeight: isMini
                                                                ? targetHeight
                                                                : MediaQuery.sizeOf(
                                                                        context)
                                                                    .height),
                                                        child:
                                                            _MinimizeOnSwipeDown(
                                                          enabled:
                                                              canSwipeDownToMinimize,
                                                          onSwipeDown: cubit
                                                              .showMiniPlayer,
                                                          child: videoPlayer,
                                                        )),
                                                    if (!isFullScreen)
                                                      ConditionalWrap(
                                                          wrapIf: !isMini,
                                                          wrapper: (child) =>
                                                              Expanded(
                                                                  child: child),
                                                          child: DeviceWidget(
                                                              orientation:
                                                                  orientation,
                                                              portraitTabletAsPhone:
                                                                  true,
                                                              tablet:
                                                                  const TabletExpandedPlayer(),
                                                              phone:
                                                                  const ExpandedPlayer()))
                                                  ],
                                                )),
                                            if (!isFullScreen && !isMini)
                                              DeviceWidget(
                                                  orientation: orientation,
                                                  portraitTabletAsPhone: true,
                                                  phone:
                                                      const SizedBox.shrink(),
                                                  tablet: const Expanded(
                                                      flex: 1,
                                                      child:
                                                          ExpandedSideBar())),
                                            ConditionalWrap(
                                                wrapper: (child) => Flexible(
                                                    fit: FlexFit.tight,
                                                    flex: 2,
                                                    child: child),
                                                wrapIf: isMini,
                                                child: const MiniPlayer()),
                                            if (isMini)
                                              GestureDetector(
                                                onTap: cubit.hide,
                                                child: const Padding(
                                                  padding: EdgeInsets.all(8.0),
                                                  child: Icon(Icons.clear),
                                                ),
                                              )
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MinimizeOnSwipeDown extends StatefulWidget {
  final bool enabled;
  final VoidCallback onSwipeDown;
  final Widget child;

  const _MinimizeOnSwipeDown({
    required this.enabled,
    required this.onSwipeDown,
    required this.child,
  });

  @override
  State<_MinimizeOnSwipeDown> createState() => _MinimizeOnSwipeDownState();
}

class _MinimizeOnSwipeDownState extends State<_MinimizeOnSwipeDown> {
  static const _swipeDistance = 200.0;

  int? _pointer;
  Offset? _startPosition;

  void _pointerDown(PointerDownEvent event) {
    if (widget.enabled && _pointer == null) {
      _pointer = event.pointer;
      _startPosition = event.position;
    }
  }

  void _pointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer || _startPosition == null) {
      return;
    }

    final distance = event.position - _startPosition!;
    _pointer = null;
    _startPosition = null;

    if (widget.enabled &&
        distance.dy > _swipeDistance &&
        distance.dy > distance.dx.abs()) {
      widget.onSwipeDown();
    }
  }

  void _pointerCancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) {
      _pointer = null;
      _startPosition = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _pointerDown,
      onPointerUp: _pointerUp,
      onPointerCancel: _pointerCancel,
      child: widget.child,
    );
  }
}
