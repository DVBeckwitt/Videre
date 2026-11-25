import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/services/music_listening_history.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/utils.dart' show selectKeys;
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

Future<void> showMusicListeningTimeline(BuildContext context,
    {required String trackId,
    required String title,
    bool inPlayer = false}) async {
  final app = context.read<AppCubit>();
  final owner = app.state;
  final database = db;
  bool isCurrent(AppState state) =>
      !app.isClosed &&
      identical(db, database) &&
      db.profileId == owner.profileId &&
      state.profileId == owner.profileId &&
      state.sessionRevision == owner.sessionRevision &&
      state.server == owner.server &&
      !state.globalLoading &&
      !state.sessionRecoveryRequired;

  if (!isCurrent(owner)) return;
  final history = MusicListeningHistory.forProfile(database, owner.profileId);
  await showDialog<void>(
    context: context,
    useRootNavigator: false,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (context) {
      final timeline = BlocBuilder<AppCubit, AppState>(
        bloc: app,
        builder: (context, _) => ListenableBuilder(
          listenable: history.changes,
          builder: (context, _) => _ListeningTimeline(
            title: title,
            events:
                isCurrent(app.state) ? history.events(trackId: trackId) : null,
          ),
        ),
      );
      return inPlayer ? PlayerModalBackHandler(child: timeline) : timeline;
    },
  );
}

class _ListeningTimeline extends StatelessWidget {
  const _ListeningTimeline({
    required this.title,
    required this.events,
  });

  final String title;
  final List<MusicListeningEvent>? events;

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final material = MaterialLocalizations.of(context);
    final events = this.events;
    return Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent(),
      },
      child: AlertDialog(
        title: Text(locals.musicListeningTimeline),
        content: events == null
            ? Text(locals.musicSourceUnavailable)
            : SizedBox(
                width: 420,
                height: (MediaQuery.sizeOf(context).height * .45)
                    .clamp(0.0, 360.0)
                    .toDouble(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                    Expanded(
                      child: events.isEmpty
                          ? Text(locals.musicListeningTimelineEmpty)
                          : _TimelineEvents(events: events),
                    ),
                  ],
                ),
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(material.closeButtonLabel),
          ),
        ],
      ),
    );
  }
}

class _TimelineEvents extends StatelessWidget {
  const _TimelineEvents({required this.events});

  final List<MusicListeningEvent> events;

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final material = MaterialLocalizations.of(context);
    final use24Hours = MediaQuery.alwaysUse24HourFormatOf(context);
    return ListView.builder(
      itemCount: events.length,
      itemBuilder: (context, index) {
        final event = events[index];
        final local = event.playedAt.toLocal();
        return Focus(
          key: ValueKey(event.id),
          autofocus: isTv && index == 0,
          canRequestFocus: isTv,
          child: Builder(
            builder: (context) => ListTile(
              tileColor: Focus.of(context).hasPrimaryFocus
                  ? Theme.of(context).colorScheme.secondaryContainer
                  : null,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: Text(material.formatFullDate(local)),
              subtitle: Text(event.isLegacy
                  ? locals.musicListeningTimelineLegacy
                  : material.formatTimeOfDay(TimeOfDay.fromDateTime(local),
                      alwaysUse24HourFormat: use24Hours)),
            ),
          ),
        );
      },
    );
  }
}
