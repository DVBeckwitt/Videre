import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:clipious/music/services/music_media_save.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/utils/motion.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/app/views/components/player_placeholder.dart';
import 'package:clipious/player/views/components/video_retry_notice.dart';
import 'package:clipious/player/views/components/player.dart';
import 'package:clipious/podcasts/views/podcast_player_controls.dart';

import '../../../player/states/player.dart';
import '../../../settings/states/settings.dart';
import '../../../music/views/components/music_selection_feedback.dart';
import '../../../player/views/components/mini_player_aware.dart';
import '../../../utils.dart';
import '../../states/app.dart';

@RoutePage()
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _musicDock = MiniPlayerDockController();
  MusicMediaSave? _mediaSave;
  AppLifecycleListener? _mediaSaveLifecycle;
  StreamSubscription<bool>? _mediaCardTaps;

  @override
  void initState() {
    super.initState();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final mediaSave = _mediaSave = context.read<PlayerCubit>().musicMediaSave;
    mediaSave.addListener(_scheduleMediaSave);
    _mediaSaveLifecycle = AppLifecycleListener(onResume: _scheduleMediaSave);
    _mediaCardTaps = AudioService.notificationClicked.skip(1).listen((clicked) {
      if (clicked) mediaSave.open();
    });
    _scheduleMediaSave();
  }

  void _scheduleMediaSave() {
    final binding = WidgetsBinding.instance;
    if (_mediaSave?.hasReadyRequest != true ||
        binding.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    binding.addPostFrameCallback((_) {
      if (mounted && binding.lifecycleState == AppLifecycleState.resumed) {
        unawaited(_showMediaSave());
      }
    });
    binding.ensureVisualUpdate();
  }

  Future<void> _showMediaSave() async {
    final mediaSave = _mediaSave;
    final request = mediaSave?.take();
    if (mediaSave == null || request == null) return;
    try {
      await MusicLibraryActions.savePlaybackEntry(context, request.entry,
          deviceTrack: request.deviceTrack, isCurrent: request.isCurrent);
    } finally {
      mediaSave.finish();
    }
  }

  @override
  void dispose() {
    _mediaSave?.removeListener(_scheduleMediaSave);
    _mediaSaveLifecycle?.dispose();
    unawaited(_mediaCardTaps?.cancel());
    _musicDock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final deviceType = getDeviceType();
      final orientation =
          context.select((PlayerCubit value) => value.state.orientation);

      final bool globalLoading =
          context.select((AppCubit value) => value.state.globalLoading);
      final playerHorizontalPosition = orientation == Orientation.landscape &&
              deviceType == DeviceType.tablet
          ? getFractionOfAvailableSpace(context, tabletMiniPlayerFraction)
          : const Size(0, 0);
      var colors = Theme.of(context).colorScheme;
      final podcasts = context.read<PlayerCubit>().podcasts;
      final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
      final slimMusicNavigation = context.select((SettingsCubit? cubit) =>
          cubit?.state.musicLayout.slimNavigation ?? false);
      // Routed pages sit inside MiniPlayerAware's SafeArea. Their AppBars do
      // not cover the status inset, so give that inset a theme-owned fallback
      // when the expanded Music AppBar (with light icons) leaves the viewport.
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: (colors.brightness == Brightness.dark
                ? SystemUiOverlayStyle.light
                : SystemUiOverlayStyle.dark)
            .copyWith(
                statusBarColor: colors.surface,
                systemNavigationBarColor: colors.surface),
        child: ListenableBuilder(
          listenable: Listenable.merge([podcasts, _musicDock]),
          builder: (context, _) {
            final docked = deviceType == DeviceType.phone && _musicDock.active;
            final miniSuppressed = docked &&
                keyboardInset > 0 &&
                constraints.maxHeight -
                        MediaQuery.paddingOf(context).top -
                        keyboardInset <
                    kToolbarHeight + targetHeight + 84;
            final compact = usesCompactMusicNavigation(context);
            final navigationInset = docked && keyboardInset == 0
                ? phoneNavigationHeight(context, compact: compact) +
                    phoneNavigationHeight(context,
                        compact: compact || slimMusicNavigation)
                : 0.0;
            return MiniPlayerDock(
              controller: _musicDock,
              active: docked,
              keyboardVisible: keyboardInset > 0,
              miniSuppressed: miniSuppressed,
              child: Container(
                color: colors.surface,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: MiniPlayerAware(
                        reserveSpace: !docked,
                        child: const AutoRouter(),
                      ),
                    ),
                    if (!podcasts.active && !miniSuppressed)
                      Positioned(
                          key: const ValueKey('mini-player-placeholder'),
                          left: playerHorizontalPosition.width,
                          bottom: docked ? navigationInset + keyboardInset : 0,
                          right: playerHorizontalPosition.width,
                          child: SafeArea(child: const PlayerPlaceHolder())),
                    if (!podcasts.active)
                      Player(constraints.maxHeight,
                          key: const ValueKey('main-player'),
                          navigationInset: navigationInset,
                          suppressMini: miniSuppressed),
                    if (podcasts.active && !globalLoading && !miniSuppressed)
                      Positioned(
                          left: playerHorizontalPosition.width,
                          right: playerHorizontalPosition.width,
                          bottom: navigationInset + keyboardInset,
                          child: SafeArea(
                              top: false,
                              child: PodcastPlaybackBar(controller: podcasts))),
                    if (!globalLoading && !podcasts.active)
                      const Positioned.fill(child: PlayerRetryIndicator()),
                    const MusicSelectionFeedback(),
                    if (globalLoading)
                      Positioned(
                          child: Container(
                              color: colors.surface.withValues(alpha: 0.5),
                              child: const Center(
                                child: MotionLoadingIndicator(
                                    child: CircularProgressIndicator()),
                              )))
                  ],
                ),
              ),
            );
          },
        ),
      );
    });
  }
}
