import 'package:flutter/material.dart';

import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../playlists/models/playlist_reference.dart';
import '../../../playlists/services/playlist_progress.dart';
import '../../../videos/models/db/progress.dart';
import '../../../videos/models/video.dart';

/// Music keeps its catalog labels and bookmarks while sharing playlist progress.
class MusicPlaylistResume extends StatelessWidget {
  final PlaylistReference reference;
  final List<Video> videos;
  final bool enabled;
  final Future<void> Function(int index, Duration position) onPlay;

  const MusicPlaylistResume({
    super.key,
    required this.reference,
    required this.videos,
    required this.onPlay,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final database = db.forProfile(reference.profileId);
    final progress =
        PlaylistProgressService.forProfile(database, reference.profileId);
    return AnimatedBuilder(
        animation:
            Listenable.merge([playbackHistoryRevision, progress.changes]),
        builder: (context, _) {
          if (db.profileId != reference.profileId) {
            return const SizedBox.shrink();
          }
          final checkpoint = progress.get(reference);
          if (checkpoint == null) return const SizedBox.shrink();
          final locals = AppLocalizations.of(context)!;
          final target = checkpoint.resolve(videos);
          if (target == null) {
            return checkpoint.completed
                ? const SizedBox.shrink()
                : Text(locals.playlistResumeUnavailable);
          }
          final position = target.missing || checkpoint.completed
              ? Duration.zero
              : database
                  .getVideoPlaybackProgress(target.video.videoId)
                  .resumePosition(durationSeconds: target.video.lengthSeconds);
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (target.missing) Text(locals.playlistResumeUnavailable),
                TextButton.icon(
                    key: const ValueKey('music-playlist-resume'),
                    onPressed:
                        enabled ? () => onPlay(target.index, position) : null,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(target.missing
                        ? locals.playlistContinueNext
                        : locals.playlistResume)),
              ]);
        });
  }
}
