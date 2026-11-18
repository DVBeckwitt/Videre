import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../models/playlist.dart';
import '../../models/playlist_reference.dart';
import '../../states/playlist.dart';
import 'playlist_server_save_button.dart';

class PlaylistInformation extends StatelessWidget {
  final Playlist? playlist;
  final PlaylistReference? reference;
  final bool complete;
  final bool enabled;
  final bool compact;
  final bool showServerCopy;
  const PlaylistInformation(
      {super.key,
      this.playlist,
      this.reference,
      this.complete = true,
      this.enabled = true,
      this.compact = false,
      this.showServerCopy = true});

  @override
  Widget build(BuildContext context) {
    final cubit = this.playlist == null ? context.watch<PlaylistCubit>() : null;
    final playlist = this.playlist ?? cubit!.state.playlist;
    final reference = this.reference ?? cubit?.reference;
    final loaded = cubit?.loader.complete ?? this.complete;
    final locals = AppLocalizations.of(context)!;
    final durations = playlist.videos
        .where((video) => video.liveNow != true && video.isUpcoming != true)
        .map((video) => video.lengthSeconds)
        .whereType<int>()
        .where((duration) => duration > 0)
        .toList();
    final complete = loaded &&
        playlist.videos.length == playlist.videoCount &&
        durations.length == playlist.videos.length;
    final elapsed = Duration(
        seconds: durations.fold<int>(0, (total, value) => total + value));
    final minutes = (elapsed.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    final duration = elapsed.inHours > 0
        ? '${elapsed.inHours}:$minutes:$seconds'
        : '$minutes:$seconds';
    final updated = playlist.updated;
    final date = updated != null && updated > 0 && updated < 8640000000000
        ? MaterialLocalizations.of(context).formatMediumDate(
            DateTime.fromMillisecondsSinceEpoch(updated * 1000))
        : null;
    final details = [
      if (compact && playlist.author.trim().isNotEmpty) playlist.author,
      locals.nVideos(playlist.videoCount),
      if (durations.isEmpty && playlist.videoCount > 0)
        locals.playlistDurationUnknown
      else if (complete)
        locals.playlistTotalDuration(duration)
      else
        locals.playlistKnownDuration(duration),
      if (date == null)
        locals.playlistUpdatedUnknown
      else
        locals.playlistUpdated(date),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (compact)
            Text(details.join(' · '),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant))
          else
            ...details.map(Text.new),
          if (showServerCopy &&
              reference != null &&
              (playlist.isLocal || reference.kind == PlaylistSourceKind.public))
            PlaylistServerSaveButton(
                playlist: playlist,
                reference: reference,
                enabled: enabled && loaded && (cubit?.canPlayEntries ?? true)),
        ],
      ),
    );
  }
}
