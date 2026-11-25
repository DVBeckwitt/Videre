import 'package:clipious/utils/motion.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/tv/screens/tv_player_view.dart';
import 'package:clipious/router.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/compact_video.dart';

import '../../../utils/views/components/placeholders.dart';
import '../../states/history.dart';

Future<void> openHistoryEntry(
    BuildContext context, HistorySource source, Video video,
    {required bool television}) async {
  final cached = source.cached(video.videoId);
  final music = source.opensMusic(video, cached);
  final download =
      source == HistorySource.server ? null : cached?.replayDownload(db);
  if (download != null) {
    if (television) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) =>
              TvPlayerScreen.download(download: download, fromMusic: music)));
    } else {
      await context
          .read<PlayerCubit>()
          .playOfflineVideos([download], fromMusic: music);
    }
    return;
  }
  if (!music) {
    final router = AutoRouter.of(context);
    if (television) {
      await router.push(TvVideoRoute(videoId: video.videoId));
    } else {
      await router.push(VideoRoute(videoId: video.videoId));
    }
    return;
  }
  try {
    await MusicScreen.playTracks(context, [video],
        queueTitle: AppLocalizations.of(context)!.history);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context)!.musicPlaybackError)));
    }
  }
}

class HistoryVideoView extends StatelessWidget {
  final String videoId;
  final VoidCallback? onLongPress;
  final HistorySource source;

  const HistoryVideoView(
      {super.key,
      required this.videoId,
      this.onLongPress,
      this.source = HistorySource.device});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) =>
          HistoryItemCubit(HistoryItemState(videoId: videoId), source: source),
      child: BlocBuilder<HistoryItemCubit, HistoryItemState>(
          builder: (context, state) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: onLongPress,
          child: AnimatedCrossFade(
            firstChild: const CompactVideoPlaceHolder(),
            secondChild: state.cachedVid != null
                ? CompactVideo(
                    musicArtwork: source == HistorySource.music,
                    onTap: () => openHistoryEntry(
                        context, source, state.cachedVid!.toVideo(),
                        television: false),
                    video: state.cachedVid?.toVideo(),
                  )
                : const CompactVideoPlaceHolder(),
            crossFadeState: state.loading
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            duration: AppMotion.duration(context),
          ),
        );
      }),
    );
  }
}
