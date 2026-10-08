import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart';
import '../../../player/states/player.dart';
import '../../../player/views/tv/screens/tv_player_view.dart';
import '../../../settings/models/db/video_filter.dart';
import '../../../utils.dart';
import '../../../utils/views/tv/components/tv_button.dart';
import '../../../videos/models/video.dart';
import '../../../videos/views/components/compact_video.dart';

class ContinueWatching extends StatefulWidget {
  const ContinueWatching({super.key});

  @override
  State<ContinueWatching> createState() => _ContinueWatchingState();
}

class _ContinueWatchingState extends State<ContinueWatching> {
  Future<void> resume([Video? video]) async {
    if (isTv) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => TvPlayerScreen(
              videos: video == null ? [] : [video],
              resumeSession: video == null)));
    } else {
      final player = context.read<PlayerCubit>();
      if (video == null) {
        await player.resumeSession();
      } else {
        await player.playVideo([video]);
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
      valueListenable: playbackHistoryRevision,
      builder: (context, _, __) => BlocBuilder<PlayerCubit, PlayerState>(
            buildWhen: (before, after) =>
                before.currentlyPlaying?.videoId !=
                    after.currentlyPlaying?.videoId ||
                before.offlineCurrentlyPlaying?.videoId !=
                    after.offlineCurrentlyPlaying?.videoId ||
                before.isHidden != after.isHidden,
            builder: (context, state) {
              final locals = AppLocalizations.of(context)!;
              final progress = {
                for (final p in db.getAllProgress()) p.videoId: p.progress
              };
              final history = db
                  .getLocalHistory()
                  .where((v) {
                    final value = progress[v.videoId] ?? 0;
                    return value > 0 && value < 0.9;
                  })
                  .map((v) => v.toVideo())
                  .toList();
              return FutureBuilder<List<Video>>(
                  future: VideoFilter.filterVideos(history),
                  builder: (context, snapshot) {
                    final videos =
                        filteredVideos(snapshot.data ?? []).take(10).toList();
                    final saved = context.read<PlayerCubit>().savedSession;
                    final canResume = !state.hasVideo &&
                        saved != null &&
                        (!isTv || saved.offlineIds.isEmpty) &&
                        (saved.videos.isNotEmpty ||
                            (db
                                    .getDownloadByVideoId(saved.currentId)
                                    ?.downloadComplete ??
                                false));
                    if (videos.isEmpty && !canResume)
                      return const SizedBox.shrink();
                    final resumeButton = TextButton.icon(
                        onPressed: resume,
                        icon: const Icon(Icons.play_arrow),
                        label: Text(locals.resumeQueue));
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(children: [
                          Expanded(
                              child: Text(locals.continueWatching,
                                  style:
                                      Theme.of(context).textTheme.titleSmall)),
                          if (canResume)
                            isTv
                                ? TvButton(
                                    onPressed: (_) => resume(),
                                    child: IgnorePointer(child: resumeButton))
                                : resumeButton,
                        ]),
                        if (videos.isNotEmpty)
                          SizedBox(
                            height: compactVideoHeight + innerHorizontalPadding,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: videos.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(width: 8),
                              itemBuilder: (context, index) {
                                final video = videos[index];
                                final tile = CompactVideo(
                                    video: video,
                                    onTap: isTv ? null : () => resume(video));
                                return SizedBox(
                                    width: 320,
                                    child: isTv
                                        ? TvButton(
                                            onPressed: (_) => resume(video),
                                            onFocusChanged: (focused) {
                                              if (focused)
                                                Scrollable.ensureVisible(
                                                    context,
                                                    duration:
                                                        animationDuration);
                                            },
                                            child: IgnorePointer(child: tile))
                                        : tile);
                              },
                            ),
                          ),
                      ],
                    );
                  });
            },
          ));
}
