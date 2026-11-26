import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../models/music_track.dart';
import '../../services/music_visibility.dart';
import 'music_library_actions.dart';

String _expiryLabel(BuildContext context, DateTime expiresAt) {
  final local = expiresAt.toLocal();
  final material = MaterialLocalizations.of(context);
  return AppLocalizations.of(context)!.musicDiscoverySnoozeUntil(
      material.formatMediumDate(local),
      material.formatTimeOfDay(TimeOfDay.fromDateTime(local),
          alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context)));
}

Future<void> showMusicDiscoverySnooze(
    BuildContext context,
    MusicVisibility visibility,
    MusicTrack track,
    bool Function() isCurrent) async {
  if (!isCurrent()) return;
  final session = MusicLibrarySession(context.read<AppCubit>());
  final messenger = ScaffoldMessenger.of(context);
  final duration = await session.showDialog<Duration>(context, (context) {
    final locals = AppLocalizations.of(context)!;
    return SimpleDialog(title: Text(locals.musicSnoozeDiscovery), children: [
      for (final (days, label) in [
        (1, locals.musicSnoozeOneDay),
        (7, locals.musicSnoozeOneWeek),
        (30, locals.musicSnoozeOneMonth),
      ])
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, Duration(days: days)),
          child: Text(label),
        ),
    ]);
  });
  if (duration == null ||
      !context.mounted ||
      !session.isCurrent ||
      !isCurrent()) {
    return;
  }
  try {
    await visibility.snooze(track, duration);
    if (!messenger.mounted || !context.mounted || !session.isCurrent) return;
    final snooze = visibility.activeSnoozes
        .where((entry) => entry.videoId == track.videoId)
        .firstOrNull;
    if (snooze == null) return;
    messenger.showSnackBar(SnackBar(
        content: Text(
            '${track.title}\n${_expiryLabel(context, snooze.expiresAt)}')));
  } catch (_) {
    if (messenger.mounted && context.mounted && session.isCurrent) {
      messenger.showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context)!.recommendationError)));
    }
  }
}

Future<void> showMusicDiscoverySnoozes(
    BuildContext context, MusicVisibility visibility) async {
  final session = MusicLibrarySession(context.read<AppCubit>());
  final messenger = ScaffoldMessenger.of(context);
  await session.showDialog<void>(context, (context) {
    final locals = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: visibility,
      builder: (context, _) {
        final snoozes = visibility.activeSnoozes;
        return AlertDialog(
          title: Text(locals.musicDiscoverySnoozedSongs),
          scrollable: true,
          content: snoozes.isEmpty
              ? Text(locals.musicNoDiscoverySnoozes)
              : ListBody(children: [
                  for (final snooze in snoozes)
                    ListTile(
                      key: ValueKey('music-snoozed-${snooze.videoId}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(snooze.title),
                      subtitle: Text(_expiryLabel(context, snooze.expiresAt)),
                      trailing: IconButton(
                        tooltip: locals.musicEndDiscoverySnooze,
                        icon: const Icon(Icons.restore_rounded),
                        onPressed: () async {
                          if (!session.isCurrent) return;
                          try {
                            await visibility.endSnooze(snooze.videoId);
                          } catch (_) {
                            if (messenger.mounted && session.isCurrent) {
                              messenger.showSnackBar(SnackBar(
                                  content: Text(locals.recommendationError)));
                            }
                          }
                        },
                      ),
                    ),
                ]),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(MaterialLocalizations.of(context).closeButtonLabel),
            ),
          ],
        );
      },
    );
  });
}
