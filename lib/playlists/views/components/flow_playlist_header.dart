// Flutter port of Flow's PlaylistDetailHeader.kt at 565d1f7a (GPL-3.0).
// Artwork, playlist references and actions use Videre's existing services.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/views/components/thumbnail.dart';
import '../../models/playlist.dart';
import '../../states/playlist.dart';
import 'playlist_playback_actions.dart';

class FlowPlaylistHeader extends StatelessWidget {
  final List<Widget> secondaryActions;

  const FlowPlaylistHeader({
    super.key,
    this.secondaryActions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final playlist = context.watch<PlaylistCubit>().state.playlist;
    final theme = Theme.of(context);
    final locals = AppLocalizations.of(context)!;
    final title = playlist.playlistId == localWatchLaterId
        ? locals.watchLater
        : playlist.title;
    final cover = playlist.videos
        .where((video) =>
            !video.filtered &&
            !video.filterHide &&
            (video.thumbnails.isNotEmpty ||
                video.musicMetadata?.thumbnails.isNotEmpty == true))
        .firstOrNull;
    final decoration = BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(18),
    );
    final placeholder = Center(
      child: Icon(Icons.playlist_play_rounded,
          size: 58, color: theme.colorScheme.onSurfaceVariant),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: cover == null
                ? DecoratedBox(decoration: decoration, child: placeholder)
                : Thumbnail(
                    thumbnails: cover.thumbnails,
                    images: cover.musicMetadata?.thumbnails.isNotEmpty == true
                        ? cover.musicMetadata!.thumbnails
                        : cover.deArrowThumbnailUrl == null
                            ? cover.videoThumbnails
                            : null,
                    decoration: decoration,
                    fallback: placeholder,
                  ),
          ),
          const SizedBox(height: 18),
          Semantics(
            header: true,
            child: Text(title, style: theme.textTheme.headlineSmall),
          ),
          PlaylistPlaybackActions(
              connected: true, secondaryActions: secondaryActions),
        ],
      ),
    );
  }
}
