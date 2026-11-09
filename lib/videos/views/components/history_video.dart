import 'package:clipious/utils/motion.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/router.dart';
import 'package:clipious/videos/views/components/compact_video.dart';

import '../../../utils/views/components/placeholders.dart';
import '../../states/history.dart';

class HistoryVideoView extends StatelessWidget {
  final String videoId;

  const HistoryVideoView({super.key, required this.videoId});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => HistoryItemCubit(HistoryItemState(videoId: videoId)),
      child: BlocBuilder<HistoryItemCubit, HistoryItemState>(
          builder: (context, state) {
        return AnimatedCrossFade(
          firstChild: const CompactVideoPlaceHolder(),
          secondChild: state.cachedVid != null
              ? CompactVideo(
                  onTap: () async {
                    final video = state.cachedVid!.toVideo();
                    if (video.musicMetadata == null) {
                      AutoRouter.of(context)
                          .push(VideoRoute(videoId: video.videoId));
                      return;
                    }
                    try {
                      await MusicScreen.playTracks(context, [video]);
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(AppLocalizations.of(context)!
                                .musicPlaybackError)));
                      }
                    }
                  },
                  video: state.cachedVid?.toVideo(),
                )
              : const CompactVideoPlaceHolder(),
          crossFadeState: state.loading
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          duration: AppMotion.duration(context),
        );
      }),
    );
  }
}
