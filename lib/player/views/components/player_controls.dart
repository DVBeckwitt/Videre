import 'package:clipious/utils/motion.dart';
import 'package:clipious/utils/views/components/motion_animation.dart';
import 'dart:math';

import 'package:clipious/globals.dart';
import 'package:clipious/main.dart';
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/models/backend_recovery.dart';
import 'package:clipious/player/views/components/backend_recovery_notice.dart';
import 'package:clipious/player/views/components/player_backend_picker.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/player/views/components/backend_request_indicator.dart';
import 'package:clipious/player/views/components/video_retry_notice.dart';
import 'package:clipious/player/views/components/sleep_timer.dart';
import 'package:clipious/player/views/components/playback_speed_controls.dart';
import 'package:clipious/player/views/components/playback_speed_quick_controls.dart';
import 'package:clipious/player/views/components/flow_watch_transport.dart';
import 'package:clipious/player/views/components/flow_video_gestures.dart';
import 'package:clipious/player/views/components/minimize_on_swipe_down.dart';
import 'package:clipious/player/views/components/remote_control.dart';
import 'package:clipious/player/views/components/system_setting_slider.dart';
import 'package:clipious/player/views/components/seek_preview.dart';
import 'package:clipious/player/views/components/subtitle_size_picker.dart';
import 'package:clipious/player/views/components/video_display_mode_picker.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/views/screens/add_server.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';

import '../../../utils.dart';
import '../../../videos/models/video.dart';
import '../../states/audio_player.dart';
import '../../states/player_controls.dart';
import '../../states/video_player.dart';

class PlayerControls extends StatelessWidget {
  final MediaPlayerCubit? mediaPlayerCubit;

  const PlayerControls({super.key, this.mediaPlayerCubit});

  Future<void> showPlaybackSpeedSelection(
      BuildContext context, MediaPlayerCubit player) async {
    Navigator.of(context).pop();
    await showPlaybackSpeedSheet(
      context,
      initialSpeed: player.getSpeed(),
      onChanged: player.setSpeed,
      initialPitchSemitones: player.getPitchSemitones(),
      onPitchChanged: !kIsWeb && defaultTargetPlatform == TargetPlatform.android
          ? player.setPitchSemitones
          : null,
    );
  }

  Future<void> showPlayerTrackSelection(
      BuildContext context, PlayerControlsState _,
      {required List<String> tracks,
      required int selected,
      required Function(int index) onSelected,
      String? help,
      bool announceSelection = false}) async {
    final widgets = <Widget>[
      if (help != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: Text(help, key: const ValueKey('onion-quality-help')),
        ),
    ];

    for (int i = 0; i < tracks.length; i++) {
      widgets.add(ListTile(
          selected: announceSelection && selected == i,
          onTap: () {
            Navigator.of(context).pop();
            onSelected(i);
          },
          leading:
              selected == i ? const Icon(Icons.check) : const SizedBox.shrink(),
          title: Text(tracks[i])));
    }

    showSafeModalBottomSheet(
      showDragHandle: true,
      isScrollControlled: true,
      context: context,
      builder: (context) {
        return PlayerModalBackHandler(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: widgets,
            ),
          ),
        );
      },
    );
  }

  void showOptionMenu(BuildContext context, PlayerControlsState controls) {
    late MediaPlayerCubit pc;
    var player = context.read<PlayerCubit>();
    if (mediaPlayerCubit != null) {
      pc = mediaPlayerCubit!;
    } else if (player.state.isAudio) {
      pc = context.read<AudioPlayerCubit>();
    } else {
      pc = context.read<VideoPlayerCubit>();
    }
    var locals = AppLocalizations.of(context)!;
    var videoTracks = pc.getVideoTracks();
    final audioTracks = List<String>.of(pc.getAudioTracks());
    final subtitles = List<String>.of(pc.getSubtitles());
    final queueId = player.state.currentQueueId;
    final generation = player.backendPlaybackGeneration;
    final modeGeneration = player.playbackPositionGeneration;
    final source = player.state.currentlyPlaying;
    final profile = db.profileId;
    final watchAudioPlayer = pc is AudioPlayerCubit &&
            player.state.isAudio &&
            source != null &&
            source.musicMetadata == null
        ? pc
        : null;
    final watchAudioTracks =
        List.of(watchAudioPlayer?.watchAudioTracks ?? const []);
    var preparingQuality = false;
    bool current() =>
        !pc.isClosed &&
        !player.isClosed &&
        player.state.currentQueueId == queueId &&
        player.backendPlaybackGeneration == generation;
    bool watchAudioCurrent() =>
        context.mounted &&
        current() &&
        modeGeneration == player.playbackPositionGeneration &&
        db.profileId == profile &&
        player.state.isAudio &&
        !player.state.isClosing &&
        !player.state.isHidden &&
        player.state.currentlyPlaying?.videoId == source?.videoId &&
        player.state.currentlyPlaying?.musicMetadata == null;
    void qualityFailure() {
      if (context.mounted && current()) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(locals.couldntLoadVideo)));
      }
    }

    showSafeModalBottomSheet(
      isScrollControlled: true,
      showDragHandle: true,
      context: context,
      builder: (ctx) {
        return PlayerModalBackHandler(
            child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PlaybackSpeedQuickControls(
                initialSpeed: pc.getSpeed(),
                onChanged: pc.setSpeed,
                onAdvanced: () => showPlaybackSpeedSelection(context, pc),
              ),
              if (pc is VideoPlayerCubit)
                ListTile(
                  key: const ValueKey('player-video-display-open'),
                  leading: const Icon(Icons.aspect_ratio),
                  title: Text(locals.videoDisplay),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    showVideoDisplayModePicker(context);
                  },
                ),
              if (canChoosePlayerBackend(player.state))
                ListTile(
                  key: const ValueKey('player-backend-open'),
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(locals.backendChoose),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    showPlayerBackendPicker(context, player: player);
                  },
                ),
              if (subtitles.isNotEmpty)
                ListTile(
                  onTap: () {
                    Navigator.of(context).pop();
                    if (!current() ||
                        !listEquals(subtitles, pc.getSubtitles())) {
                      return;
                    }
                    showPlayerTrackSelection(
                      context,
                      controls,
                      tracks: subtitles,
                      selected: pc.selectedSubtitle(),
                      onSelected: (index) {
                        if (current() &&
                            listEquals(subtitles, pc.getSubtitles())) {
                          pc.selectSubtitle(index);
                        }
                      },
                    );
                  },
                  leading: const Icon(Icons.subtitles),
                  title: Text(locals.subtitles),
                ),
              if (pc is VideoPlayerCubit && pc.hasSubtitleTracks)
                ListTile(
                  key: const ValueKey('player-subtitle-size-open'),
                  leading: const Icon(Icons.format_size),
                  title: Text(locals.subtitleFontSize),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    showSubtitleSizePicker(context);
                  },
                ),
              if (videoTracks.isNotEmpty)
                ListTile(
                  onTap: () async {
                    if (preparingQuality) return;
                    preparingQuality = true;
                    final ready = pc is! VideoPlayerCubit ||
                        await pc.prepareVideoTracks();
                    preparingQuality = false;
                    if (!context.mounted || !ctx.mounted || !current()) return;
                    final tracks = pc.getVideoTracks();
                    Navigator.of(ctx).pop();
                    if (!ready) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(locals.couldntLoadVideo)));
                    }
                    showPlayerTrackSelection(
                      context,
                      controls,
                      tracks: tracks,
                      selected: pc.selectedVideoTrack(),
                      onSelected: (index) {
                        if (current()) {
                          final selected =
                              pc.getVideoTracks().indexOf(tracks[index]);
                          if (pc is VideoPlayerCubit) {
                            pc.selectVideoTrack(selected,
                                onQualityFailure: qualityFailure);
                          } else {
                            pc.selectVideoTrack(selected);
                          }
                        }
                      },
                      help: pc is VideoPlayerCubit && pc.isOnionPlayback
                          ? locals.onionVideoQualityHint
                          : null,
                    );
                  },
                  leading: const Icon(Icons.hd),
                  title: Text(locals.quality),
                ),
              if (watchAudioPlayer != null && watchAudioTracks.length > 1)
                ListTile(
                  key: const ValueKey('player-audio-track-open'),
                  leading: const Icon(Icons.music_note),
                  title: Text(locals.playbackAudioTrack),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    if (!watchAudioCurrent() ||
                        !listEquals(watchAudioTracks,
                            watchAudioPlayer.watchAudioTracks)) {
                      return;
                    }
                    final labels = [
                      for (final track in watchAudioTracks)
                        track.label.trim().isEmpty
                            ? locals.audio
                            : track.label.trim(),
                    ];
                    showPlayerTrackSelection(
                      context,
                      controls,
                      tracks: [
                        for (final (index, label) in labels.indexed)
                          labels.indexOf(label) == labels.lastIndexOf(label)
                              ? label
                              : '$label (${watchAudioTracks[index].id})',
                      ],
                      selected: watchAudioTracks.indexWhere((track) =>
                          track.id ==
                          watchAudioPlayer.selectedWatchAudioTrackId),
                      announceSelection: true,
                      onSelected: (index) async {
                        final track = watchAudioTracks[index];
                        if (!watchAudioCurrent() ||
                            !watchAudioPlayer.watchAudioTracks
                                .contains(track)) {
                          return;
                        }
                        final changed = await watchAudioPlayer
                            .selectWatchAudioTrack(track.id);
                        if (!changed &&
                            context.mounted &&
                            watchAudioCurrent()) {
                          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                              SnackBar(
                                  content: Text(
                                      locals.playbackAudioTrackSwitchFailed)));
                        }
                      },
                    );
                  },
                ),
              if (pc is! AudioPlayerCubit && audioTracks.isNotEmpty)
                ListTile(
                  onTap: () {
                    Navigator.of(context).pop();
                    if (!current() ||
                        !listEquals(audioTracks, pc.getAudioTracks())) {
                      return;
                    }
                    showPlayerTrackSelection(
                      context,
                      controls,
                      tracks: audioTracks,
                      selected: pc.selectedAudioTrack(),
                      onSelected: (index) {
                        // A queued recording can replace this one while the
                        // picker is open. Its old indexes belong to this exact
                        // track list, never the replacement recording.
                        if (current() &&
                            listEquals(audioTracks, pc.getAudioTracks())) {
                          pc.selectAudioTrack(index);
                        }
                      },
                    );
                  },
                  leading: const Icon(Icons.music_note),
                  title: Text(locals.audio),
                ),
              if (pc.hasDashToggle() &&
                  !(player.state.currentlyPlaying?.liveNow ?? false))
                ListTile(
                  onTap: () async {
                    if (preparingQuality) return;
                    preparingQuality = true;
                    final ready = pc is! VideoPlayerCubit ||
                        await pc.prepareVideoTracks();
                    preparingQuality = false;
                    if (!context.mounted || !ctx.mounted || !current()) return;
                    Navigator.of(ctx).pop();
                    if (!ready) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(locals.couldntLoadVideo)));
                      return;
                    }
                    if (pc is VideoPlayerCubit) {
                      pc.toggleDash(onQualityFailure: qualityFailure);
                    } else {
                      pc.toggleDash();
                    }
                  },
                  leading: Icon(
                    Icons.stream,
                    color: pc.isUsingDash() ? Colors.green : null,
                  ),
                  title: Text(locals.useDash),
                ),
              player.state.hasTimer
                  ? ListTile(
                      leading: const Icon(Icons.bedtime_off),
                      title: Text(locals.cancelSleepTimer),
                      onTap: () {
                        Navigator.of(context).pop();
                        player.cancelSleep();
                      },
                    )
                  : ListTile(
                      leading: const Icon(Icons.bedtime),
                      title: Text(locals.sleepTimer),
                      onTap: () async {
                        Navigator.of(context).pop();
                        final sleepTimer = await SleepTimerSheet.show(context);
                        if (sleepTimer != null) {
                          player.sleep(sleepTimer);
                        }
                      })
            ],
          ),
        ));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    var textTheme = Theme.of(context).textTheme;
    var player = context.read<PlayerCubit>();
    final videoId = context.select((PlayerCubit cubit) =>
        cubit.state.currentlyPlaying?.videoId ??
        cubit.state.offlineCurrentlyPlaying?.videoId);
    return Theme(
      data: ThemeData(
          useMaterial3: true,
          colorScheme: darkColorScheme,
          sliderTheme: SliderThemeData(
              inactiveTrackColor: darkColorScheme.secondaryContainer),
          progressIndicatorTheme: ProgressIndicatorThemeData(
              circularTrackColor:
                  darkColorScheme.secondaryContainer.withValues(alpha: 0.8))),
      child: BlocProvider(
        // Drop an in-progress drag when the queue advances to another video.
        key: ValueKey(videoId),
        create: (context) =>
            PlayerControlsCubit(const PlayerControlsState(), player),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final playerState = context.watch<PlayerControlsCubit>().state;

            bool isMini =
                context.select((PlayerCubit cubit) => cubit.state.isMini);
            final isDragging =
                context.select((PlayerCubit cubit) => cubit.state.isDragging);
            bool isPlaying =
                context.select((PlayerCubit cubit) => cubit.state.isPlaying);
            Video? currentlyPlaying = context
                .select((PlayerCubit cubit) => cubit.state.currentlyPlaying);
            final watchAudio = mediaPlayerCubit is AudioPlayerCubit &&
                currentlyPlaying != null &&
                currentlyPlaying.musicMetadata == null;
            final flowWatch = !isTv &&
                currentlyPlaying != null &&
                !context.select((PlayerCubit cubit) => cubit.state.isAudio) &&
                playerState.fullScreenState != FullScreenState.fullScreen;
            bool hasQueue =
                context.select((PlayerCubit cubit) => cubit.state.hasQueue);
            bool isPip =
                context.select((PlayerCubit cubit) => cubit.state.isPip);
            final recovery = context
                .select((PlayerCubit cubit) => cubit.state.backendRecovery);
            final retryingBackend =
                recovery?.phase == BackendRecoveryPhase.trying;
            final failedRecovery =
                recovery?.phase == BackendRecoveryPhase.failed;
            final failureReason = context
                .select((PlayerCubit cubit) => cubit.playbackFailureReason);
            final canChooseBackend = context.select(
                (PlayerCubit cubit) => canChoosePlayerBackend(cubit.state));
            final requestedBackend = context
                .select((PlayerCubit cubit) => cubit.state.requestedBackend);
            final retryingMetadata = context.select((PlayerCubit cubit) =>
                PlayerRetryIndicator.visibleFor(cubit.state));
            int totalFastForward = context
                .select((PlayerCubit cubit) => cubit.state.totalFastForward);
            int totalRewind =
                context.select((PlayerCubit cubit) => cubit.state.totalRewind);

            bool screenControlsEnabled = context.select(
                (SettingsCubit settings) => settings.state.screenControls);

            String videoTitle = context.select((PlayerCubit cubit) =>
                cubit.state.currentlyPlaying?.title ??
                cubit.state.offlineCurrentlyPlaying?.title ??
                '');

            bool hasTimer =
                context.select((PlayerCubit cubit) => cubit.state.hasTimer);

            bool isPausedAndDone = playerState.position.inMilliseconds >
                    player.duration.inMilliseconds * 0.99 &&
                context.select((SettingsCubit value) =>
                    value.state.playerRepeatMode == PlayerRepeat.noRepeat);

            var cubit = context.read<PlayerControlsCubit>();
            final videoPlayer = mediaPlayerCubit;
            final flowGestures = !kIsWeb &&
                defaultTargetPlatform == TargetPlatform.android &&
                !isTv &&
                !isMini &&
                !isPip &&
                videoPlayer is VideoPlayerCubit;
            final indicatorStyle = Theme.of(context).textTheme.bodySmall;
            final indicatorLineHeight = MediaQuery.textScalerOf(context)
                    .scale(indicatorStyle?.fontSize ?? 12) *
                (indicatorStyle?.height ?? 1.33);
            final requestIndicatorTop = max(
                playerState.fullScreenState == FullScreenState.fullScreen
                    ? 52.0
                    : 8.0,
                playerState.showSponsorBlocked
                    ? indicatorLineHeight + 34
                    : 8.0);
            final showRequestedBackend =
                requestedBackend != null && !isMini && !isPip;
            final retryTop = showRequestedBackend && playerState.displayControls
                ? requestIndicatorTop + indicatorLineHeight + 16
                : 0.0;

            // to allow or not dragging to adjust brightness and volume
            var canDragToAdjustDeviceSettings = screenControlsEnabled &&
                playerState.fullScreenState == FullScreenState.fullScreen &&
                !playerState.displayControls;
            // The expanded surface follows the finger until release. Its
            // legacy drag changes isMini mid-gesture, so only use its callbacks
            // for standalone/compact surfaces or a drag that began there and
            // is already in progress.
            final scopedMinimize = !isMini &&
                MinimizeDragScope.maybeOf(context) != null &&
                (context
                        .findAncestorWidgetOfExactType<MinimizeOnSwipeDown>()
                        ?.enabled ??
                    false);
            final canDragPlayer =
                playerState.fullScreenState != FullScreenState.fullScreen &&
                    !playerState.displayControls &&
                    (!scopedMinimize || isDragging);

            return BlocListener<PlayerCubit, PlayerState>(
              listenWhen: (previous, current) =>
                  previous.mediaEvent != current.mediaEvent,
              listener: (BuildContext context, state) {
                cubit.onStreamEvent(state.mediaEvent);
              },
              child: _PlayerSurface(
                wrapVideoGestures: flowGestures
                    ? (child) => FlowVideoGestures(
                          key: ValueKey(player.state.currentQueueId),
                          video: currentlyPlaying,
                          duration: playerState.duration,
                          readPosition: () => player.state.position,
                          canSeek: playerState.duration > Duration.zero &&
                              currentlyPlaying?.liveNow != true &&
                              !playerState.errored &&
                              !playerState.draggingPositionSlider &&
                              !retryingBackend,
                          toggleControls: () {
                            if (cubit.state.displayControls) {
                              cubit.hideControls();
                            } else {
                              cubit.showControls();
                            }
                          },
                          togglePlayback: () {
                            if (!player.state.isPlaying && isPausedAndDone) {
                              player.seek(Duration.zero);
                            }
                            player.togglePlaying();
                          },
                          rewind: cubit.doubleTapRewind,
                          fastForward: cubit.doubleTapFastForward,
                          seek: (position) => cubit
                              .onScrubbed(position.inMilliseconds.toDouble()),
                          child: child,
                        )
                    : null,
                speedBoostPlayer: !isMini &&
                        !isPip &&
                        isPlaying &&
                        !playerState.errored &&
                        videoPlayer is VideoPlayerCubit
                    ? videoPlayer
                    : null,
                // Keep the active recognizer until it settles even if controls
                // appear mid-drag. Disposing it would skip end/cancel entirely.
                onVerticalDragEnd: canDragPlayer
                    ? player.videoDraggedEnd
                    : isDragging
                        ? (_) => player.videoDragCancelled()
                        : null,
                // Keep vertical arena ownership even when the raw listener
                // moves the surface, so a vertical pull cannot become a seek.
                onVerticalDragUpdate: canDragPlayer
                    ? player.videoDragged
                    : scopedMinimize
                        ? (_) {}
                        : null,
                onVerticalDragStart:
                    canDragPlayer ? player.videoDragStarted : null,
                onVerticalDragCancel: canDragPlayer || isDragging
                    ? player.videoDragCancelled
                    : null,
                child: SafeArea(
                  top:
                      playerState.fullScreenState == FullScreenState.fullScreen,
                  bottom:
                      playerState.fullScreenState == FullScreenState.fullScreen,
                  left:
                      playerState.fullScreenState == FullScreenState.fullScreen,
                  right:
                      playerState.fullScreenState == FullScreenState.fullScreen,
                  child: Stack(
                    fit: StackFit.expand,
                    alignment: Alignment.topCenter,
                    children: [
                      if (!isMini && playerState.showSponsorBlocked)
                        Positioned(
                            top: 10,
                            left: 10,
                            child: MotionAnimation(
                                builder: (context, controller) => Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                          color: Colors.black
                                              .withValues(alpha: 0.5),
                                          borderRadius:
                                              BorderRadius.circular(20)),
                                      child: Row(
                                        children: [
                                          const Icon(
                                            Icons.fast_forward,
                                            color: Colors.white,
                                            size: 15,
                                          ),
                                          const SizedBox(
                                            width: 5,
                                          ),
                                          Text(
                                            locals.sponsorSkipped,
                                            style: textTheme.bodySmall
                                                ?.copyWith(color: Colors.white),
                                          ),
                                        ],
                                      ),
                                    )
                                        .animate(controller: controller)
                                        .slideX(
                                            duration:
                                                AppMotion.duration(context),
                                            curve: Curves.easeInOutQuad)
                                        .fadeIn(
                                            duration:
                                                AppMotion.fadeDuration(context))
                                        .fadeOut(
                                            delay: const Duration(seconds: 1),
                                            duration:
                                                AppMotion.fadeDuration(context))
                                        .slideX(
                                            end: -0.5,
                                            duration:
                                                AppMotion.duration(context),
                                            curve: Curves.easeInOutQuad,
                                            delay:
                                                const Duration(seconds: 1)))),
                      if (!isMini && !isPip)
                        Positioned(
                            left: 0,
                            right: 0,
                            top: 0,
                            bottom: 0,
                            child: Row(
                              children: [
                                Expanded(
                                    child: GestureDetector(
                                        behavior: HitTestBehavior.translucent,
                                        onVerticalDragStart:
                                            canDragToAdjustDeviceSettings
                                                ? (details) {
                                                    cubit
                                                        .startBrightnessAdjustments(
                                                            details);
                                                  }
                                                : null,
                                        onVerticalDragUpdate:
                                            canDragToAdjustDeviceSettings
                                                ? (details) {
                                                    cubit.updateBrightness(
                                                        details, constraints);
                                                  }
                                                : null,
                                        // Outside fullscreen, let the outer
                                        // player drag recognizer own this drag.
                                        onVerticalDragEnd:
                                            playerState.fullScreenState ==
                                                    FullScreenState.fullScreen
                                                ? (_) => cubit
                                                    .stopBrightnessAdjustments()
                                                : null,
                                        onTap: flowGestures
                                            ? null
                                            : playerState.justDoubleTappedSkip
                                                ? cubit.doubleTapRewind
                                                : playerState.displayControls
                                                    ? cubit.hideControls
                                                    : cubit.showControls,
                                        onDoubleTap: flowGestures ||
                                                playerState.justDoubleTappedSkip
                                            ? null
                                            : cubit.doubleTapRewind,
                                        child: DoubleTapButton(
                                            stepText:
                                                '-$totalRewind ${locals.secondsShortForm}',
                                            opacity: playerState
                                                .doubleTapRewindedOpacity,
                                            icon: Icons.fast_rewind))),
                                Expanded(
                                    child: GestureDetector(
                                        onVerticalDragStart:
                                            canDragToAdjustDeviceSettings
                                                ? (details) {
                                                    cubit
                                                        .startVolumeAdjustments(
                                                            details);
                                                  }
                                                : null,
                                        onVerticalDragUpdate:
                                            canDragToAdjustDeviceSettings
                                                ? (details) {
                                                    cubit.updateVolume(
                                                        details, constraints);
                                                  }
                                                : null,
                                        onVerticalDragEnd: playerState
                                                    .fullScreenState ==
                                                FullScreenState.fullScreen
                                            ? (_) =>
                                                cubit.stopVolumeAdjustments()
                                            : null,
                                        onTap: flowGestures
                                            ? null
                                            : playerState.justDoubleTappedSkip
                                                ? cubit.doubleTapFastForward
                                                : playerState.displayControls
                                                    ? cubit.hideControls
                                                    : cubit.showControls,
                                        behavior: HitTestBehavior.translucent,
                                        onDoubleTap: flowGestures ||
                                                playerState.justDoubleTappedSkip
                                            ? null
                                            : cubit.doubleTapFastForward,
                                        child: DoubleTapButton(
                                          stepText:
                                              '+$totalFastForward ${locals.secondsShortForm}',
                                          opacity: playerState
                                              .doubleTapFastForwardedOpacity,
                                          icon: Icons.fast_forward,
                                        ))),
                              ],
                            )),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        top: 0,
                        child: isMini || isPip
                            ? const SizedBox.shrink()
                            : playerState.displayControls
                                ? GestureDetector(
                                    onTap: flowGestures
                                        ? null
                                        : cubit.hideControls,
                                    child: Container(
                                      decoration: flowWatch
                                          ? const BoxDecoration(
                                              gradient: LinearGradient(
                                                begin: Alignment.topCenter,
                                                end: Alignment.bottomCenter,
                                                colors: [
                                                  Colors.black54,
                                                  Colors.black26,
                                                  Colors.black54
                                                ],
                                              ),
                                            )
                                          : const BoxDecoration(
                                              color: Color(0x66000000)),
                                      child: Column(
                                        children: [
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.end,
                                            children: [
                                              if (flowWatch) ...[
                                                IconButton(
                                                  key: const ValueKey(
                                                      'watch-minimize'),
                                                  tooltip:
                                                      MaterialLocalizations.of(
                                                              context)
                                                          .backButtonTooltip,
                                                  onPressed:
                                                      player.showMiniPlayer,
                                                  icon: const Icon(Icons
                                                      .keyboard_arrow_down_rounded),
                                                ),
                                                const Spacer(),
                                              ],
                                              if (playerState.fullScreenState ==
                                                  FullScreenState.fullScreen)
                                                Expanded(
                                                    child: Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                          left: 8.0),
                                                  child: Text(
                                                    videoTitle,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: textTheme.bodyMedium
                                                        ?.copyWith(
                                                            color: Colors.white
                                                                .withValues(
                                                                    alpha:
                                                                        0.8)),
                                                  ),
                                                )),
                                              RemoteControlButton(
                                                  player: player),
                                              IconButton(
                                                  onPressed: () =>
                                                      player.enterPip(),
                                                  icon: const Icon(Icons
                                                      .picture_in_picture)),
                                              IconButton(
                                                  tooltip: watchAudio
                                                      ? MaterialLocalizations
                                                              .of(context)
                                                          .showMenuTooltip
                                                      : null,
                                                  onPressed: () =>
                                                      showOptionMenu(
                                                          context, playerState),
                                                  icon: const Icon(
                                                      Icons.more_vert))
                                            ],
                                          ),
                                          Expanded(child: Container()),
                                          if (!flowWatch) ...[
                                            Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.end,
                                              children: [
                                                playerState.muted
                                                    ? IconButton(
                                                        onPressed: () {
                                                          player
                                                              .setMuted(false);
                                                          cubit
                                                              .hideControlsDebounce();
                                                        },
                                                        icon: const Icon(
                                                            Icons.volume_off))
                                                    : IconButton(
                                                        onPressed: () {
                                                          player.setMuted(true);
                                                          cubit
                                                              .hideControlsDebounce();
                                                        },
                                                        icon: const Icon(
                                                            Icons.volume_up)),
                                                switch (playerState
                                                    .fullScreenState) {
                                                  FullScreenState.fullScreen =>
                                                    IconButton(
                                                        onPressed: () => player
                                                            .setFullScreen(
                                                                FullScreenState
                                                                    .notFullScreen),
                                                        icon: const Icon(Icons
                                                            .fullscreen_exit)),
                                                  FullScreenState
                                                        .notFullScreen =>
                                                    IconButton(
                                                        onPressed: () => player
                                                            .setFullScreen(
                                                                FullScreenState
                                                                    .fullScreen),
                                                        icon: const Icon(
                                                            Icons.fullscreen)),
                                                }
                                              ],
                                            ),
                                            const SizedBox(
                                              height: 15,
                                            )
                                          ],
                                        ],
                                      ),
                                    ),
                                  )
                                : const SizedBox.expand(),
                      ),
                      if (flowWatch && !isMini && !isPip)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: FlowWatchTransport(
                            position: playerState.position,
                            duration: playerState.duration,
                            buffer: playerState.buffer,
                            sponsorIntervals: context.select(
                              (PlayerCubit cubit) =>
                                  cubit.state.sponsorSegments,
                            ),
                            showActions: playerState.displayControls,
                            showTime: playerState.justDoubleTappedSkip ||
                                playerState.draggingPositionSlider,
                            isLive: currentlyPlaying.liveNow == true,
                            muted: playerState.muted,
                            onToggleMute: () {
                              player.setMuted(!playerState.muted);
                              cubit.hideControlsDebounce();
                            },
                            onFullscreen: () => player
                                .setFullScreen(FullScreenState.fullScreen),
                            onInteract: cubit.hideControlsDebounce,
                            onScrub: cubit.onScrubDrag,
                            onScrubFinished: cubit.onScrubbed,
                          ),
                        ),
                      if (!flowWatch &&
                          (playerState.displayControls ||
                              playerState.justDoubleTappedSkip) &&
                          !(currentlyPlaying?.liveNow ?? false))
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: Stack(
                            children: [
                              Container(
                                decoration: playerState.justDoubleTappedSkip
                                    ? BoxDecoration(
                                        gradient: LinearGradient(
                                            begin: Alignment.bottomCenter,
                                            end: Alignment.topCenter,
                                            colors: [
                                            Colors.black.withValues(alpha: 1),
                                            Colors.black.withValues(alpha: 0)
                                          ]))
                                    : null,
                                child: Padding(
                                    padding: const EdgeInsets.only(
                                        top: 16.0, right: 8),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: SizedBox(
                                              height: 25,
                                              child: Slider(
                                                min: 0,
                                                value: min(
                                                    playerState
                                                        .position.inMilliseconds
                                                        .toDouble(),
                                                    playerState
                                                        .duration.inMilliseconds
                                                        .toDouble()),
                                                max: playerState
                                                    .duration.inMilliseconds
                                                    .toDouble(),
                                                secondaryTrackValue: min(
                                                    playerState
                                                        .buffer.inMilliseconds
                                                        .toDouble(),
                                                    playerState
                                                        .duration.inMilliseconds
                                                        .toDouble()),
                                                onChangeStart:
                                                    cubit.onScrubDrag,
                                                onChangeEnd: cubit.onScrubbed,
                                                onChanged: cubit.onScrubDrag,
                                              )),
                                        ),
                                        Text(
                                          '${prettyDurationCustom(playerState.position)} / ${prettyDurationCustom(playerState.duration)}',
                                          style: textTheme.bodySmall
                                              ?.copyWith(color: Colors.white),
                                        ),
                                      ],
                                    )),
                              ),
                            ],
                          ),
                        ),
                      if (!isMini &&
                          !isPip &&
                          playerState.draggingPositionSlider &&
                          !(currentlyPlaying?.liveNow ?? false))
                        Positioned(
                          bottom: 48,
                          left: 0,
                          right: 0,
                          child: Center(
                              child: SeekPreview(
                            video: currentlyPlaying,
                            position: playerState.position,
                            duration: playerState.duration,
                            width: min(160, constraints.maxWidth * 0.4),
                          )),
                        ),
                      if (!isMini &&
                          !isPip &&
                          playerState.displayControls &&
                          !playerState.draggingPositionSlider)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              if (hasQueue)
                                IconButton(
                                    onPressed: () {
                                      player.playPrevious();
                                      cubit.removeError();
                                      cubit.hideControlsDebounce();
                                    },
                                    icon: const Icon(
                                      Icons.skip_previous,
                                      size: 20,
                                    )),
                              IconButton(
                                  onPressed: () => player.rewind(),
                                  icon: const Icon(
                                    Icons.fast_rewind,
                                    size: 30,
                                  )),
                              IconButton(
                                style: flowWatch
                                    ? IconButton.styleFrom(
                                        backgroundColor: Colors.black45,
                                        foregroundColor: Colors.white,
                                        minimumSize: const Size.square(60),
                                      )
                                    : null,
                                onPressed: () {
                                  if (isPlaying) {
                                    player.pause();
                                  } else if (isPausedAndDone) {
                                    player.seek(Duration.zero);
                                    player.play();
                                  } else {
                                    player.play();
                                  }
                                },
                                icon: Icon(
                                    isPlaying
                                        ? Icons.pause
                                        : isPausedAndDone
                                            ? Icons.refresh
                                            : Icons.play_arrow,
                                    size: flowWatch ? 38 : 55),
                              ),
                              IconButton(
                                  onPressed: () => player.fastForward(),
                                  icon: const Icon(
                                    Icons.fast_forward,
                                    size: 30,
                                  )),
                              if (hasQueue)
                                IconButton(
                                    onPressed: () {
                                      player.playNext();
                                      cubit.removeError();
                                      cubit.hideControlsDebounce();
                                    },
                                    icon: const Icon(
                                      Icons.skip_next,
                                      size: 20,
                                    )),
                            ],
                          ),
                        ),
                      if (playerState.buffering &&
                          recovery == null &&
                          !retryingMetadata)
                        const Center(
                          child: FractionallySizedBox(
                            heightFactor: 0.3,
                            child: AspectRatio(
                                aspectRatio: 1,
                                child: MotionLoadingIndicator(
                                    child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ))),
                          ),
                        ),
                      // show icon when sleep is enabled or not
                      MotionAnimation(
                          builder: (context, controller) => Positioned(
                                  right: 20,
                                  bottom: 20,
                                  child: Icon(hasTimer
                                      ? Icons.bedtime_outlined
                                      : Icons.bedtime_off_outlined))
                              .animate(
                                  controller: controller,
                                  target: hasTimer ? 1 : 0)
                              .fadeIn(
                                  duration: AppMotion.fadeDuration(context),
                                  curve: animationCurve)
                              .slideY(
                                  duration: AppMotion.duration(context),
                                  curve: animationCurve,
                                  begin: 2,
                                  end: 0)
                              .fadeOut(
                                  delay: const Duration(seconds: 3),
                                  duration: AppMotion.fadeDuration(context),
                                  curve: animationCurve)
                              .slideY(
                                  delay: const Duration(seconds: 3),
                                  duration: AppMotion.duration(context),
                                  curve: animationCurve,
                                  begin: 0,
                                  end: 2)),

                      Positioned(
                              top: constraints.maxHeight * 0.15,
                              bottom: constraints.maxHeight * 0.15,
                              right: 20,
                              child: SystemSettingsSlider(
                                  type: SystemSliderType.brightness,
                                  value: playerState.systemBrightness))
                          .animate(
                            target: playerState.showBrightnessSlider ? 1 : 0,
                          )
                          .slideX(
                              begin: 2,
                              end: 0,
                              duration: AppMotion.duration(
                                  context, animationDuration ~/ 2),
                              curve: animationCurve)
                          .fade(
                              begin: 0,
                              end: 1,
                              duration: AppMotion.fadeDuration(
                                  context, animationDuration * 0.75),
                              curve: animationCurve),
                      Positioned(
                              top: constraints.maxHeight * 0.15,
                              bottom: constraints.maxHeight * 0.15,
                              left: 20,
                              child: SystemSettingsSlider(
                                  type: SystemSliderType.volume,
                                  value: playerState.systemVolume))
                          .animate(
                            target: playerState.showVolumeSlider ? 1 : 0,
                          )
                          .slideX(
                              begin: -2,
                              end: 0,
                              duration: AppMotion.duration(
                                  context, animationDuration ~/ 2),
                              curve: animationCurve)
                          .fade(
                              begin: 0,
                              end: 1,
                              duration: AppMotion.fadeDuration(
                                  context, animationDuration * 0.75),
                              curve: animationCurve),
                      // Recovery status stays visible when the controls fade.
                      if (recovery != null && !failedRecovery)
                        Positioned.fill(
                          top: retryTop,
                          child: BackendRecoveryNotice(
                            recovery: recovery,
                            compact: isMini || isPip,
                          ),
                        ),
                      if (failedRecovery ||
                          (recovery == null &&
                              (playerState.errored || failureReason != null)))
                        Positioned.fill(
                          child: ColoredBox(
                            color: Colors.black.withValues(alpha: 0.8),
                            child: Center(
                              child: isMini || isPip
                                  ? const Icon(Icons.error_outline,
                                      color: Colors.white)
                                  : SingleChildScrollView(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 36),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Semantics(
                                            liveRegion: true,
                                            child: Text(
                                              playbackFailureText(
                                                  locals, failureReason,
                                                  recovery: recovery),
                                              style: const TextStyle(
                                                  color: Colors.white),
                                              textAlign: TextAlign.center,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Wrap(
                                            alignment: WrapAlignment.center,
                                            children: [
                                              TextButton.icon(
                                                onPressed: () {
                                                  cubit.removeError();
                                                  player.retryCurrentVideo();
                                                },
                                                icon: const Icon(Icons.refresh),
                                                label: Text(locals.retry),
                                              ),
                                              if (canChooseBackend)
                                                TextButton.icon(
                                                  key: const ValueKey(
                                                      'player-backend-error-open'),
                                                  onPressed: () =>
                                                      showPlayerBackendPicker(
                                                          context,
                                                          player: player),
                                                  icon: const Icon(
                                                      Icons.dns_outlined),
                                                  label: Text(
                                                      locals.backendChoose),
                                                ),
                                              if (currentlyPlaying != null)
                                                TextButton.icon(
                                                  onPressed: () => AddServerScreen
                                                      .showConnectionHelp(
                                                          context,
                                                          videoId:
                                                              currentlyPlaying
                                                                  .videoId),
                                                  icon: const Icon(
                                                      Icons.wifi_find),
                                                  label: Text(
                                                      locals.connectionHelp),
                                                ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      if (showRequestedBackend)
                        Positioned(
                          left: flowWatch ? 54 : 8,
                          right: 152,
                          top: requestIndicatorTop,
                          // Request details belong to the controls. Recovery
                          // notices above retain their independent lifetime.
                          child: ExcludeSemantics(
                            excluding: !playerState.displayControls,
                            child: AnimatedOpacity(
                              opacity: playerState.displayControls ? 1 : 0,
                              duration: AppMotion.fadeDuration(context),
                              child: BackendRequestIndicator(
                                playback: requestedBackend,
                                overlay: true,
                                compact: flowWatch || retryingBackend,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PlayerSurface extends StatefulWidget {
  const _PlayerSurface({
    required this.wrapVideoGestures,
    required this.speedBoostPlayer,
    required this.onVerticalDragStart,
    required this.onVerticalDragUpdate,
    required this.onVerticalDragEnd,
    required this.onVerticalDragCancel,
    required this.child,
  });

  final Widget Function(Widget)? wrapVideoGestures;
  final VideoPlayerCubit? speedBoostPlayer;
  final GestureDragStartCallback? onVerticalDragStart;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;
  final GestureDragCancelCallback? onVerticalDragCancel;
  final Widget child;

  @override
  State<_PlayerSurface> createState() => _PlayerSurfaceState();
}

class _PlayerSurfaceState extends State<_PlayerSurface> {
  VoidCallback? _restoreSpeed;

  void _startSpeedBoost(LongPressStartDetails details) {
    final restore = widget.speedBoostPlayer?.startSpeedBoost(onEnded: () {
      if (mounted && _restoreSpeed != null) {
        setState(() => _restoreSpeed = null);
      }
    });
    if (restore != null) setState(() => _restoreSpeed = restore);
  }

  void _restorePlaybackSpeed() {
    final restore = _restoreSpeed;
    _restoreSpeed = null;
    restore?.call();
  }

  void _endSpeedBoost() {
    if (_restoreSpeed != null) setState(_restorePlaybackSpeed);
  }

  @override
  void didUpdateWidget(covariant _PlayerSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.speedBoostPlayer != oldWidget.speedBoostPlayer) {
      _restorePlaybackSpeed();
    }
  }

  @override
  void dispose() {
    _restorePlaybackSpeed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep the recognizer above the overlays so auto-hide cannot end the hold.
    final canBoost = widget.speedBoostPlayer != null;
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        if (canBoost)
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            // A deliberate hold should respond sooner than the platform's
            // 500 ms context-menu gesture, without stealing taps or drags.
            () => LongPressGestureRecognizer(
                duration: const Duration(milliseconds: 200)),
            (recognizer) => recognizer
              ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context)
              ..onLongPressDown = (details) {
                final width = context.size!.width;
                final x = details.localPosition.dx;
                // Reject before the deadline can take a center-button tap.
                if (x >= width / 3 && x <= width * 2 / 3) {
                  recognizer.resolve(GestureDisposition.rejected);
                }
              }
              ..onLongPressStart = _startSpeedBoost
              ..onLongPressUp = _endSpeedBoost
              ..onLongPressCancel = _endSpeedBoost,
          ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: widget.onVerticalDragStart,
        onVerticalDragUpdate: widget.onVerticalDragUpdate,
        onVerticalDragEnd: widget.onVerticalDragEnd,
        onVerticalDragCancel: widget.onVerticalDragCancel,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            widget.wrapVideoGestures?.call(widget.child) ?? widget.child,
            if (_restoreSpeed != null)
              const Positioned.fill(
                child: IgnorePointer(
                  child: Align(
                    alignment: Alignment(0, -0.55),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.all(Radius.circular(20)),
                      ),
                      child: Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child:
                            Text('2×', style: TextStyle(color: Colors.white)),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class DoubleTapButton extends StatelessWidget {
  final double opacity;
  final IconData icon;
  final String stepText;

  const DoubleTapButton(
      {super.key,
      required this.opacity,
      required this.icon,
      required this.stepText});

  @override
  Widget build(BuildContext context) {
    var textTheme = Theme.of(context).textTheme;
    return AnimatedContainer(
      curve: Curves.easeInOutQuad,
      margin: EdgeInsets.all(opacity == 1 ? 50 : 0),
      decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: opacity == 1 ? 0.3 : 0),
          shape: BoxShape.circle),
      duration: AppMotion.duration(context, const Duration(milliseconds: 150)),
      height: double.infinity,
      child: AnimatedOpacity(
        opacity: opacity,
        duration: AppMotion.fadeDuration(
            context, Duration(milliseconds: opacity == 1 ? 150 : 500)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 50,
            ),
            Text(
              stepText,
              style: textTheme.bodySmall
                  ?.copyWith(color: Colors.white.withValues(alpha: 0.8)),
            )
          ],
        ),
      ),
    );
  }
}
