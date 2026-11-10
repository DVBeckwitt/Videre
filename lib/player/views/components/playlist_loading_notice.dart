import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../states/player.dart';

/// The queue remains usable when another playlist page is slow or unavailable.
class PlaylistLoadingNotice extends StatelessWidget {
  const PlaylistLoadingNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerCubit>();
    final locals = AppLocalizations.of(context)!;
    return ValueListenableBuilder<int>(
      valueListenable: player.playlistLoadingRevision,
      builder: (context, revision, _) {
        final failed = player.playlistLoadingError != null;
        if (!failed && !player.isPlaylistLoading) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Semantics(
            liveRegion: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!failed) const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(
                  failed
                      ? locals.playlistLoadingFailed
                      : locals.playlistLoadingMore,
                  textAlign: TextAlign.center,
                ),
                if (failed)
                  TextButton.icon(
                    onPressed: player.retryPlaylistLoading,
                    icon: const Icon(Icons.refresh),
                    label: Text(locals.retry),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
