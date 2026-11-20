import 'package:clipious/utils/motion.dart';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/views/components/music_mini_player.dart';
import 'package:clipious/music/views/components/music_player.dart';
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/player/models/flow_mini_geometry.dart';
import 'package:clipious/player/models/flow_watch_layout.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/audio_player.dart';
import 'package:clipious/player/views/components/expanded_player.dart';
import 'package:clipious/player/views/components/flow_floating_mini.dart';
import 'package:clipious/player/views/components/flow_watch_side_pane.dart';
import 'package:clipious/player/views/components/mini_player.dart';
import 'package:clipious/player/views/components/minimize_on_swipe_down.dart';
import 'package:clipious/player/views/components/video_player.dart';
import 'package:clipious/player/views/tablet/expanded_player.dart';
import 'package:clipious/player/views/tablet/expanded_side_bar.dart';
import 'package:clipious/utils/views/components/conditional_wrap.dart';
import 'package:clipious/utils/views/components/device_widget.dart';
import 'package:clipious/videos/views/components/add_to_playlist_button.dart';

import '../../../utils.dart';
import '../../../videos/models/video.dart';
import '../../../videos/views/components/video_share_button.dart';

const double tabletMiniPlayerFraction = 0.25;

class Player extends StatefulWidget {
  final double maxHeight;

  const Player(this.maxHeight, {super.key});

  @override
  State<Player> createState() => _PlayerState();
}

class _PlayerState extends State<Player> {
  final _floatingMotion = FlowFloatingMiniMotion();
  final _musicSurfaceFocus =
      FocusScopeNode(debugLabel: 'Expanded music player');
  final _minimizeMusicFocus = FocusNode(debugLabel: 'Minimize music player');
  FocusNode? _browsingFocus;
  bool _containsMusicFocus = false;
  int _focusRequest = 0;
  FlowWatchPanel? _watchPanel;
  double? _minimizeDrag;
  Object? _minimizeIdentity;
  Object? _musicMiniViewport;

  void _refreshFloating() => setState(() {});

  void _updateMusicFocus(bool contained) {
    final entering = contained && !_containsMusicFocus;
    final leaving = !contained && _containsMusicFocus;
    _containsMusicFocus = contained;
    _musicSurfaceFocus.traversalEdgeBehavior = contained
        ? TraversalEdgeBehavior.closedLoop
        : TraversalEdgeBehavior.parentScope;
    _musicSurfaceFocus.directionalTraversalEdgeBehavior = contained
        ? TraversalEdgeBehavior.stop
        : TraversalEdgeBehavior.parentScope;
    if (entering) {
      final current = FocusManager.instance.primaryFocus;
      _browsingFocus = current != null &&
              current != _musicSurfaceFocus &&
              !current.ancestors.contains(_musicSurfaceFocus)
          ? current
          : null;
    }
    if (!contained && !leaving) return;
    final request = ++_focusRequest;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || request != _focusRequest) return;
      if (!contained) {
        final previous = _browsingFocus;
        _browsingFocus = null;
        if (previous?.context?.mounted == true && previous!.canRequestFocus) {
          previous.requestFocus();
        } else {
          _musicSurfaceFocus.unfocus(
              disposition: UnfocusDisposition.previouslyFocusedChild);
        }
        return;
      }
      final current = FocusManager.instance.primaryFocus;
      final currentContext = current?.context;
      // Dialogs and sheets have their own scope. Resizing the surface beneath
      // one must not take keyboard focus back from its controls.
      if (currentContext != null &&
          ModalRoute.of(currentContext) is PopupRoute<dynamic>) {
        return;
      }
      if (current != null && current is! FocusScopeNode) {
        if (current.ancestors.contains(_musicSurfaceFocus)) return;
        if (!entering) return;
      }
      if (_minimizeMusicFocus.context?.mounted == true) {
        _minimizeMusicFocus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _musicSurfaceFocus.dispose();
    _minimizeMusicFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var themeData = Theme.of(context);
    ColorScheme colors = themeData.colorScheme;
    AppLocalizations locals = AppLocalizations.of(context)!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHeight = widget.maxHeight;
        final maxWidth = constraints.maxWidth;
        final viewport = Size(maxWidth, maxHeight);
        var cubit = context.read<PlayerCubit>();

        final bool showPlayer =
            context.select((PlayerCubit value) => value.state.hasVideo);
        final bool isPip =
            context.select((PlayerCubit value) => value.state.isPip);
        final double? requestedTop = context.select(
            (PlayerCubit value) => value.state.isPip ? 0.0 : value.state.top);
        final bool isMini =
            context.select((PlayerCubit value) => value.state.isMini) && !isPip;
        final bool isHidden =
            context.select((PlayerCubit value) => value.state.isHidden);
        final bool isAudio =
            context.select((PlayerCubit value) => value.state.isAudio);
        final bool isDragging =
            context.select((PlayerCubit value) => value.state.isDragging);
        final bool isClosing =
            context.select((PlayerCubit value) => value.state.isClosing);
        final openingSong =
            context.select((PlayerCubit value) => value.openingSongTitle);
        final Video? currentlyPlaying =
            context.select((PlayerCubit value) => value.state.currentlyPlaying);
        final music = context.select((PlayerCubit value) =>
            value.state.currentlyPlaying?.musicMetadata ??
            value.state.offlineCurrentlyPlaying?.musicMetadata);
        final isMusic = isAudio && music != null;
        final FullScreenState fullScreen =
            context.select((PlayerCubit value) => value.state.fullScreenState);
        final bool isFullScreen =
            isPip || fullScreen == FullScreenState.fullScreen;
        // Between songs the mounted Music surface can already display and
        // swipe its pending queue entry, before the decoder finishes opening.
        final showOpeningSong =
            openingSong != null && !isMusic && !isMini && !isFullScreen;
        _updateMusicFocus((isMusic && showPlayer || showOpeningSong) &&
            !isHidden &&
            !isClosing &&
            !isMini &&
            !isFullScreen);
        final double aspectRatio =
            context.select((PlayerCubit value) => value.state.aspectRatio);
        final deviceType = getDeviceType();
        final orientation =
            context.select((PlayerCubit value) => value.state.orientation);
        final flowWatch = !isTv && !isAudio && currentlyPlaying != null;
        final offlineVideo = showPlayer && !isAudio && currentlyPlaying == null;
        final expandedAudio = !isTv &&
            showPlayer &&
            isAudio &&
            !isMusic &&
            !isMini &&
            !isFullScreen;
        final needsInlineControls = offlineVideo || expandedAudio;
        final watchLayout = FlowWatchLayout.forWindow(viewport);
        final wideWatch = flowWatch &&
            watchLayout == FlowWatchLayout.wide &&
            !isMini &&
            !isFullScreen;
        final queueId =
            context.select((PlayerCubit p) => p.state.currentQueueId);
        final minimizeIdentity = (
          queueId,
          viewport,
          isAudio,
          isMini,
          isFullScreen,
          isHidden,
          isClosing
        );
        if (_minimizeIdentity != minimizeIdentity) {
          _minimizeIdentity = minimizeIdentity;
          _minimizeDrag = null;
        }
        final dragOffset = _minimizeDrag;
        final surfaceMotion = AppMotion.duration(context);
        if (!wideWatch || _watchPanel?.queueId != queueId) _watchPanel = null;

        void openWatchPanel(String title, Widget child, bool scrollable) {
          if (cubit.state.isMini || cubit.state.currentQueueId != queueId) {
            return;
          }
          setState(() => _watchPanel = (
                queueId: queueId,
                title: title,
                child: child,
                scrollable: scrollable,
              ));
        }

        final canSwipeDownToMinimize = deviceType == DeviceType.phone &&
            !isAudio &&
            !isMini &&
            !isFullScreen;
        final canDragMusic = isMusic && !isFullScreen && (isMini || isDragging);
        final floating = isMini &&
            !isFullScreen &&
            context.select(
              (PlayerCubit player) => usesFlowFloatingVideo(player.state),
            );
        if (isHidden || !showPlayer || isAudio) {
          _floatingMotion.reset();
        } else if (!floating) {
          _floatingMotion.cancel();
        }

        // The player is a sibling of the routed Scaffolds, so their keyboard
        // resizing does not move this overlay. Keep it above the keyboard and
        // bound a drag to the current viewport, including after a resize.
        final padding = MediaQuery.paddingOf(context);
        final headerHeight =
            (themeData.appBarTheme.toolbarHeight ?? kToolbarHeight) +
                padding.top;
        final phoneChrome = deviceType == DeviceType.phone ||
            (deviceType == DeviceType.tablet &&
                orientation == Orientation.portrait);
        // The legacy phone player includes a clipped bottom navigation bar.
        final inlineControlsHeight = kMinInteractiveDimension +
            16 +
            (phoneChrome
                ? .65 *
                    ((themeData.navigationBarTheme.height ?? 80) +
                        padding.bottom)
                : 0);
        var expandedVideoHeight = maxHeight;
        if (flowWatch && !isFullScreen) {
          expandedVideoHeight = max(0.0, maxHeight - padding.vertical - 120);
        } else if (needsInlineControls && !isFullScreen) {
          final bodyHeight =
              max(0.0, maxHeight - headerHeight - padding.bottom);
          expandedVideoHeight = max(0.0, bodyHeight - inlineControlsHeight);
          if (expandedAudio) {
            // Share a short viewport with the scrollable Info or Queue pane.
            expandedVideoHeight = min(expandedVideoHeight, bodyHeight / 2);
          }
        }
        final keyboardInset = isMini && !isFullScreen
            ? MediaQuery.viewInsetsOf(context).bottom
            : 0.0;
        final maxTop =
            max(0.0, maxHeight - keyboardInset - padding.bottom - targetHeight);
        final musicMiniViewport =
            (viewport, padding, keyboardInset, isDragging);
        // SafeArea applies new insets immediately. Move a compact Music bar in
        // the same frame so its fixed-height controls are never squeezed by an
        // old position during keyboard, viewport or mini-drag changes.
        final miniViewportChanged = _musicMiniViewport != null &&
            _musicMiniViewport != musicMiniViewport;
        _musicMiniViewport = isMusic && isMini && showPlayer && !isHidden
            ? musicMiniViewport
            : null;
        final top = isFullScreen
            ? 0.0
            : isDragging && requestedTop != null
                ? requestedTop
                    .clamp(min(padding.top, maxTop), maxTop)
                    .toDouble()
                : isMini
                    ? isMusic && showPlayer && !isHidden
                        ? maxTop + (isClosing ? targetHeight : 0)
                        : null
                    : requestedTop;

        final playerHorizontalPosition = orientation == Orientation.landscape &&
                isMini &&
                deviceType == DeviceType.tablet
            ? getFractionOfAvailableSpace(context, tabletMiniPlayerFraction)
            : const Size(0, 0);

        final isTablet = deviceType == DeviceType.tablet;
        final navigationBarHeight = isTablet
            ? 0.0
            : MediaQuery.textScalerOf(context).scale(12) <= 16
                ? 60.0
                : 76.0;
        final safeBottom = max(
            0.0,
            maxHeight -
                max(keyboardInset, padding.bottom + navigationBarHeight));
        final rail = isTablet &&
                MediaQuery.orientationOf(context) == Orientation.landscape
            ? 80.0
            : 0.0;
        final usable = Rect.fromLTRB(
          min(padding.left + rail, max(0, maxWidth - padding.right)),
          min(padding.top + 56, safeBottom),
          max(0, maxWidth - padding.right),
          safeBottom,
        );
        final layoutIdentity = (viewport, usable, aspectRatio, isTablet);
        final geometry = floating
            ? FlowMiniGeometry(
                viewport: viewport,
                usable: usable,
                aspectRatio: aspectRatio,
                largeWindow: isTablet,
                devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
              )
            : null;
        final miniBounds = geometry == null
            ? null
            : _floatingMotion.bounds(geometry, layoutIdentity);
        final playerBounds = miniBounds == null || !isClosing
            ? miniBounds
            : miniBounds.shift(Offset(0, maxHeight - miniBounds.top + 8));
        final tuckedSide = floating ? _floatingMotion.tuckedSide : null;

        Widget videoPlayer = showPlayer
            ? BlocBuilder<PlayerCubit, PlayerState>(
                buildWhen: (previous, current) =>
                    previous.isAudio != current.isAudio ||
                    previous.currentlyPlaying != current.currentlyPlaying ||
                    previous.offlineCurrentlyPlaying !=
                        current.offlineCurrentlyPlaying,
                builder: (context, state) {
                  return AspectRatio(
                    aspectRatio: isFullScreen
                        ? aspectRatio
                        : geometry?.boxAspectRatio ?? 16 / 9,
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

        final surface = AnimatedPositioned(
          left: playerBounds?.left ?? playerHorizontalPosition.width,
          right: playerBounds == null
              ? playerHorizontalPosition.width
              : maxWidth - playerBounds.right,
          top: dragOffset ?? playerBounds?.top ?? top,
          bottom: playerBounds != null
              ? maxHeight - playerBounds.bottom
              : dragOffset != null
                  ? -dragOffset
                  : isClosing
                      ? -targetHeight
                      : isFullScreen
                          ? 0
                          : isMini && isDragging && top != null
                              ? maxHeight - top - targetHeight
                              : cubit.getBottom + keyboardInset,
          duration: dragOffset != null ||
                  isDragging ||
                  (isMini && miniViewportChanged) ||
                  (floating && _floatingMotion.interacting)
              ? Duration.zero
              : surfaceMotion,
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            duration: AppMotion.fadeDuration(context),
            opacity: isClosing ? 0 : 1,
            child: AnimatedScale(
              scale: (isMini && isDragging) ? 0.8 : 1,
              duration: AppMotion.duration(context),
              curve: Curves.easeInOutQuad,
              child: Material(
                elevation: floating ? 8 : 0,
                borderRadius: floating ? BorderRadius.circular(12) : null,
                child: showPlayer
                    ? GestureDetector(
                        onTap: isMini && !isMusic && !floating
                            ? cubit.showBigPlayer
                            : null,
                        // The Music artwork replaces the hidden decoder's drag
                        // surface. Keep this recognizer above both presentations
                        // so crossing into the expanded view retains the gesture.
                        onVerticalDragStart:
                            canDragMusic ? cubit.videoDragStarted : null,
                        onVerticalDragUpdate:
                            canDragMusic ? cubit.videoDragged : null,
                        onVerticalDragEnd:
                            canDragMusic ? cubit.videoDraggedEnd : null,
                        onVerticalDragCancel:
                            canDragMusic ? cubit.videoDragCancelled : null,
                        child: SafeArea(
                          bottom: !isFullScreen && !isDragging && !floating,
                          top: flowWatch && !isMini && !isFullScreen,
                          left: !isFullScreen && !floating,
                          right: !isFullScreen && !floating,
                          child: AnimatedContainer(
                            duration: AppMotion.duration(context),
                            color: isMusic && !isMini
                                ? const Color(0xff121212)
                                : colors.surface,
                            padding: EdgeInsets.symmetric(
                                horizontal:
                                    isMini && !isDragging && !floating ? 7 : 0),
                            child: ClipRRect(
                              borderRadius: isMini
                                  ? BorderRadius.circular(floating ? 12 : 10)
                                  : BorderRadius.circular(0),
                              child: AnimatedContainer(
                                duration: AppMotion.duration(context),
                                decoration: BoxDecoration(
                                  color: isFullScreen || floating
                                      ? Colors.black
                                      : isMusic
                                          ? Color(
                                              isMini ? 0xff202020 : 0xff121212)
                                          : isMini && flowWatch
                                              ? colors.surfaceContainerHighest
                                              : isMini
                                                  ? colors.secondaryContainer
                                                  : colors.surface,
                                ),
                                child: LayoutBuilder(
                                    builder:
                                        (context, chromeConstraints) => Column(
                                              mainAxisSize: isMini
                                                  ? MainAxisSize.min
                                                  : MainAxisSize.max,
                                              children: [
                                                isMini ||
                                                        isPip ||
                                                        isFullScreen ||
                                                        flowWatch ||
                                                        (needsInlineControls &&
                                                            chromeConstraints
                                                                    .maxHeight <
                                                                headerHeight)
                                                    ? const SizedBox.shrink()
                                                    : ConstrainedBox(
                                                        // AppBar clips its toolbar when allocated less
                                                        // height. Keep the minimize button mounted while
                                                        // the Music surface grows from its compact bar.
                                                        constraints: BoxConstraints(
                                                            maxHeight: isMusic
                                                                ? min(
                                                                    48 +
                                                                        padding
                                                                            .top,
                                                                    chromeConstraints
                                                                        .maxHeight)
                                                                : double
                                                                    .infinity),
                                                        child:
                                                            MinimizeOnSwipeDown(
                                                                enabled:
                                                                    isMusic,
                                                                onSwipeDown: cubit
                                                                    .showMiniPlayer,
                                                                child: AppBar(
                                                                  systemOverlayStyle: isMusic
                                                                      ? SystemUiOverlayStyle
                                                                          .light
                                                                          .copyWith(
                                                                              statusBarColor: Colors.transparent)
                                                                      : null,
                                                                  backgroundColor: isMusic
                                                                      ? const Color(
                                                                          0xff121212)
                                                                      : null,
                                                                  foregroundColor:
                                                                      isMusic
                                                                          ? Colors
                                                                              .white
                                                                          : null,
                                                                  toolbarHeight:
                                                                      isMusic
                                                                          ? 48
                                                                          : null,
                                                                  centerTitle:
                                                                      isMusic,
                                                                  title: isMusic
                                                                      ? Container(
                                                                          width:
                                                                              34,
                                                                          height:
                                                                              4,
                                                                          decoration:
                                                                              BoxDecoration(
                                                                            color:
                                                                                Colors.white38,
                                                                            borderRadius:
                                                                                BorderRadius.circular(4),
                                                                          ),
                                                                        )
                                                                      : Text(locals
                                                                          .videoPlayer),
                                                                  leading:
                                                                      IconButton(
                                                                    focusNode: isMusic &&
                                                                            !showOpeningSong
                                                                        ? _minimizeMusicFocus
                                                                        : null,
                                                                    tooltip: MaterialLocalizations.of(
                                                                            context)
                                                                        .backButtonTooltip,
                                                                    icon: const Icon(
                                                                        Icons
                                                                            .expand_more),
                                                                    onPressed: cubit
                                                                        .showMiniPlayer,
                                                                  ),
                                                                  actions: isHidden ||
                                                                          openingSong !=
                                                                              null ||
                                                                          currentlyPlaying ==
                                                                              null
                                                                      ? []
                                                                      : [
                                                                          VideoShareButton(
                                                                            video:
                                                                                currentlyPlaying,
                                                                            showTimestampOption:
                                                                                true,
                                                                            inPlayer:
                                                                                true,
                                                                          ),
                                                                          if (!isMusic)
                                                                            AddToPlayListButton(
                                                                                key: ValueKey(currentlyPlaying),
                                                                                video: currentlyPlaying,
                                                                                videoId: currentlyPlaying.videoId)
                                                                        ],
                                                                ))),
                                                Flexible(
                                                  fit: isMini
                                                      ? FlexFit.loose
                                                      : FlexFit.tight,
                                                  child: AnimatedContainer(
                                                    // this is just to animate the transition to mini player
                                                    constraints: BoxConstraints(
                                                      maxHeight: isFullScreen
                                                          ? MediaQuery.of(
                                                                  context)
                                                              .size
                                                              .height
                                                          : isMini
                                                              ? miniBounds
                                                                      ?.height ??
                                                                  targetHeight
                                                              : isMusic
                                                                  ? maxHeight
                                                                  : 500,
                                                    ),
                                                    duration: floating
                                                        ? Duration.zero
                                                        : AppMotion.duration(
                                                            context),
                                                    child: LayoutBuilder(
                                                      builder: (context,
                                                          rowConstraints) {
                                                        // The watch stage animates from the floating box.
                                                        // Wait until its supporting pane fits before mounting it.
                                                        final showWatchPane = wideWatch &&
                                                            rowConstraints
                                                                    .maxWidth >=
                                                                2 * FlowWatchLayout.supportingPaneWidth +
                                                                    FlowWatchLayout
                                                                        .supportingPaneGap &&
                                                            rowConstraints
                                                                    .maxHeight >=
                                                                120;
                                                        return Row(
                                                          mainAxisAlignment: isMini
                                                              ? MainAxisAlignment
                                                                  .spaceBetween
                                                              : MainAxisAlignment
                                                                  .center,
                                                          children: [
                                                            Flexible(
                                                                fit: isMini &&
                                                                        !floating
                                                                    ? FlexFit
                                                                        .loose
                                                                    : FlexFit
                                                                        .tight,
                                                                flex: isMusic &&
                                                                        isMini
                                                                    ? 0
                                                                    : deviceType ==
                                                                            DeviceType
                                                                                .tablet
                                                                        ? 2
                                                                        : 1,
                                                                child: Offstage(
                                                                    // Retain the decoder's element slot while the
                                                                    // compact Music bar uses the complete row.
                                                                    offstage:
                                                                        isMusic &&
                                                                            isMini,
                                                                    child: SizedBox(
                                                                        width: isMusic && isMini ? targetHeight * 16 / 9 : null,
                                                                        child: LayoutBuilder(builder: (context, stageConstraints) {
                                                                          // Defer the legacy toolbar and bottom bar until they fit
                                                                          // alongside the video in the growing stage.
                                                                          final inlineVideoHeight = min(
                                                                              expandedVideoHeight,
                                                                              stageConstraints.maxWidth * 9 / 16);
                                                                          final showControls =
                                                                              !needsInlineControls || (stageConstraints.maxHeight >= inlineVideoHeight + inlineControlsHeight && stageConstraints.maxWidth >= 3 * kMinInteractiveDimension + 16);
                                                                          return Column(
                                                                            mainAxisSize: isMini
                                                                                ? MainAxisSize.min
                                                                                : MainAxisSize.max,
                                                                            mainAxisAlignment: isFullScreen
                                                                                ? MainAxisAlignment.center
                                                                                : MainAxisAlignment.start,
                                                                            crossAxisAlignment: isMini
                                                                                ? CrossAxisAlignment.start
                                                                                : CrossAxisAlignment.center,
                                                                            children: [
                                                                              Flexible(
                                                                                flex: isFullScreen || floating ? 1 : 0,
                                                                                fit: FlexFit.tight,
                                                                                child: Container(
                                                                                    // Give the seek bar the stage width even when the
                                                                                    // centered audio thumbnail is limited by height.
                                                                                    width: isFullScreen || floating || expandedAudio ? double.infinity : null,
                                                                                    // SafeArea takes effect before the floating
                                                                                    // bounds finish animating into the watch page.
                                                                                    constraints: BoxConstraints(maxHeight: min(stageConstraints.maxHeight, isMini ? miniBounds?.height ?? targetHeight : expandedVideoHeight)),
                                                                                    child: MinimizeOnSwipeDown(
                                                                                      enabled: canSwipeDownToMinimize,
                                                                                      onSwipeDown: cubit.showMiniPlayer,
                                                                                      // Keep the audio decoder at the same location
                                                                                      // while the artwork view expands or minimizes.
                                                                                      child: Offstage(
                                                                                        offstage: isMusic && !isFullScreen,
                                                                                        child: ExcludeFocus(
                                                                                          excluding: (isMusic && !isFullScreen) || tuckedSide != null,
                                                                                          child: Stack(
                                                                                            fit: StackFit.passthrough,
                                                                                            children: [
                                                                                              IgnorePointer(
                                                                                                ignoring: floating,
                                                                                                child: videoPlayer,
                                                                                              ),
                                                                                              if (geometry != null && miniBounds != null && !miniBounds.isEmpty)
                                                                                                Positioned.fill(
                                                                                                  child: FlowFloatingMiniSurface(
                                                                                                    key: const ValueKey('flow-mini-surface'),
                                                                                                    geometry: geometry,
                                                                                                    viewport: layoutIdentity,
                                                                                                    bounds: miniBounds,
                                                                                                    motion: _floatingMotion,
                                                                                                    onChanged: _refreshFloating,
                                                                                                    onExpand: () {
                                                                                                      if (!cubit.state.isClosing) cubit.showBigPlayer();
                                                                                                    },
                                                                                                    onDismiss: cubit.hide,
                                                                                                    child: FlowFloatingMiniControls(
                                                                                                      largeWindow: isTablet,
                                                                                                      scale: miniBounds.width / geometry.sizeAt(1).width,
                                                                                                    ),
                                                                                                  ),
                                                                                                ),
                                                                                            ],
                                                                                          ),
                                                                                        ),
                                                                                      ),
                                                                                    )),
                                                                              ),
                                                                              if (!isFullScreen && !floating && showControls)
                                                                                ConditionalWrap(
                                                                                    wrapIf: !isMini,
                                                                                    wrapper: (child) => Expanded(child: child),
                                                                                    child: flowWatch
                                                                                        ? ExpandedPlayer(
                                                                                            watchLayout: wideWatch && !showWatchPane ? FlowWatchLayout.medium : watchLayout,
                                                                                            onOpenPanel: showWatchPane ? openWatchPanel : null,
                                                                                          )
                                                                                        : DeviceWidget(orientation: orientation, portraitTabletAsPhone: true, tablet: const TabletExpandedPlayer(), phone: const ExpandedPlayer()))
                                                                            ],
                                                                          );
                                                                        })))),
                                                            if (showWatchPane)
                                                              SizedBox(
                                                                width: FlowWatchLayout
                                                                        .supportingPaneWidth +
                                                                    FlowWatchLayout
                                                                        .supportingPaneGap,
                                                                child: Padding(
                                                                  padding: const EdgeInsets
                                                                      .only(
                                                                      left: FlowWatchLayout
                                                                          .supportingPaneGap),
                                                                  child:
                                                                      FlowWatchSidePane(
                                                                    key: const ValueKey(
                                                                        'flow-watch-side-pane'),
                                                                    video:
                                                                        currentlyPlaying,
                                                                    panel:
                                                                        _watchPanel,
                                                                    onOpen:
                                                                        openWatchPanel,
                                                                    onClose: () =>
                                                                        setState(() =>
                                                                            _watchPanel =
                                                                                null),
                                                                  ),
                                                                ),
                                                              ),
                                                            if (!flowWatch &&
                                                                !isFullScreen &&
                                                                !isMini &&
                                                                !isMusic)
                                                              DeviceWidget(
                                                                  orientation:
                                                                      orientation,
                                                                  portraitTabletAsPhone:
                                                                      true,
                                                                  phone: const SizedBox
                                                                      .shrink(),
                                                                  tablet: const Expanded(
                                                                      flex: 1,
                                                                      child:
                                                                          ExpandedSideBar())),
                                                            if (isMini &&
                                                                !floating)
                                                              Flexible(
                                                                fit: FlexFit
                                                                    .tight,
                                                                flex: 2,
                                                                child: isMusic
                                                                    ? const MusicMiniPlayer()
                                                                    : MiniPlayer(
                                                                        watchStyle:
                                                                            flowWatch),
                                                              ),
                                                            if (isMini &&
                                                                !floating &&
                                                                flowWatch)
                                                              IconButton(
                                                                tooltip: MaterialLocalizations.of(
                                                                        context)
                                                                    .closeButtonLabel,
                                                                onPressed:
                                                                    cubit.hide,
                                                                icon: const Icon(
                                                                    Icons
                                                                        .close_rounded),
                                                              )
                                                            else if (isMini &&
                                                                !floating &&
                                                                !isMusic)
                                                              GestureDetector(
                                                                onTap:
                                                                    cubit.hide,
                                                                child:
                                                                    const Padding(
                                                                  padding:
                                                                      EdgeInsets
                                                                          .all(
                                                                              8.0),
                                                                  child: Icon(
                                                                      Icons
                                                                          .clear),
                                                                ),
                                                              )
                                                          ],
                                                        );
                                                      },
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            )),
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
        // Keep one scope mounted across mini/full and breakpoint changes so
        // the decoder is never reparented. Only expanded Music traps focus;
        // mini playback leaves the browsing page available.
        return MinimizeDragScope(
            identity: minimizeIdentity,
            onUpdate: (distance) {
              if (cubit.isClosed ||
                  cubit.state.isMini ||
                  cubit.state.isClosing ||
                  cubit.state.currentQueueId != queueId) {
                return;
              }
              final offset = distance.clamp(0.0, maxTop).toDouble();
              if (_minimizeDrag != offset) {
                setState(() => _minimizeDrag = offset);
              }
            },
            onEnd: (minimize) {
              if (_minimizeDrag != null) setState(() => _minimizeDrag = null);
              if (minimize &&
                  !cubit.isClosed &&
                  !cubit.state.isClosing &&
                  cubit.state.currentQueueId == queueId) {
                cubit.showMiniPlayer();
              }
            },
            child: FocusScope(
              node: _musicSurfaceFocus,
              child: Stack(
                children: [
                  Positioned.fill(
                      child: ExcludeFocus(
                          excluding: showOpeningSong,
                          child: Stack(children: [surface]))),
                  if (showOpeningSong)
                    Positioned.fill(
                      child: BlockSemantics(
                        child: MusicPlayerOpening(
                          onBack: cubit.showMiniPlayer,
                          backFocus: _minimizeMusicFocus,
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                            Text(openingSong,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 16),
                            const CircularProgressIndicator(),
                          ]),
                        ),
                      ),
                    ),
                  if (tuckedSide != null &&
                      miniBounds != null &&
                      !miniBounds.isEmpty &&
                      !isClosing)
                    Positioned(
                      left: tuckedSide == FlowMiniTuckSide.left
                          ? padding.left
                          : null,
                      right: tuckedSide == FlowMiniTuckSide.right
                          ? padding.right
                          : null,
                      top: (miniBounds.center.dy - min(32, usable.height / 2))
                          .clamp(usable.top,
                              usable.bottom - min(64, usable.height))
                          .toDouble(),
                      width: 48,
                      height: min(64, usable.height),
                      child: FlowMiniTuckHandle(
                        key: const ValueKey('flow-mini-tuck-handle'),
                        side: tuckedSide,
                        onUntuck: () {
                          _floatingMotion.untuck();
                          _refreshFloating();
                        },
                      ),
                    ),
                ],
              ),
            ));
      },
    );
  }
}
