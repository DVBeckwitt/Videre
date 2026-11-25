import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart' show db;
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/local_music_artist.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../screens/music.dart';
import '../screens/music_device_artist.dart';

class MusicPlayingDeviceArtists extends StatelessWidget {
  const MusicPlayingDeviceArtists({
    super.key,
    required this.byline,
    required this.occurrence,
    required this.television,
  });

  final String byline;
  final (String, int, int, String?) occurrence;
  final bool television;

  bool _current(AppCubit app, AppState original, PlayerCubit player) {
    if (app.isClosed || player.isClosed) return false;
    final session = app.state;
    final state = player.state;
    return !session.globalLoading &&
        !session.sessionRecoveryRequired &&
        session.profileId == db.profileId &&
        session.server == original.server &&
        state.isAudio &&
        !state.isHidden &&
        !state.isMini &&
        !state.isClosing &&
        player.openingMusicEntry == null &&
        occurrence ==
            (
              session.profileId,
              session.sessionRevision,
              player.playlistGeneration,
              state.currentQueueId,
            );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppCubit>();
    final player = context.watch<PlayerCubit>();
    final library = LocalMusicLibrary.instance;
    final locals = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final style = theme.textTheme.titleMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final session = app.state;
        final selection = library.selectionId;
        final track = _current(app, session, player) &&
                library.acceptsSessionSelection(selection)
            ? localMusicTrackForPlayback(occurrence.$4)
            : null;
        final credits = track == null
            ? const <LocalMusicArtistCredit>[]
            : localMusicArtistCredits(track);
        if (track == null || credits.isEmpty) {
          return Text(byline.isEmpty ? locals.onDevice : byline, style: style);
        }

        void open(String key) {
          if (!context.mounted ||
              !TickerMode.of(context) ||
              !_current(app, session, player) ||
              !library.acceptsSessionSelection(selection)) {
            return;
          }
          final current = localMusicTrackForPlayback(occurrence.$4);
          if (current == null ||
              current.playbackId != track.playbackId ||
              localMusicArtistCredit(current, key) == null) {
            return;
          }
          unawaited(MusicScreen.openPlayingSource(
            context,
            MusicDeviceArtistPage(
              selectionId: selection,
              artistKey: key,
              anchorId: track.playbackId,
            ),
            television: television,
          ));
        }

        final key =
            ValueKey(('music-player-device-artists', occurrence, selection));
        final buttonStyle = TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          alignment: AlignmentDirectional.centerStart,
          foregroundColor: theme.colorScheme.onSurfaceVariant,
        );
        final first = credits.first;
        final multiple = credits.length > 1;
        final label = Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
              child: Text(first.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
          const SizedBox(width: 4),
          Icon(multiple ? Icons.expand_more : Icons.chevron_right, size: 18),
        ]);
        if (!multiple) {
          final tooltip = locals.musicOpenNamedArtist(first.name);
          return Tooltip(
            message: tooltip,
            child: TextButton(
              key: key,
              style: buttonStyle,
              onPressed: () => open(first.key),
              child: label,
            ),
          );
        }
        return PopupMenuButton<String>(
          key: key,
          tooltip: locals.localMusicContributorCredits,
          style: buttonStyle,
          onSelected: open,
          itemBuilder: (_) => [
            for (final (index, credit) in credits.indexed)
              PopupMenuItem(
                value: credit.key,
                child: PlayerModalBackHandler(
                  active: index == 0,
                  priority: 5,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(credit.name),
                    subtitle: Text(credit.roles
                        .map((role) => localMusicArtistRoleLabel(locals, role))
                        .join(' · ')),
                  ),
                ),
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: label,
          ),
        );
      },
    );
  }
}
