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

class _ListeningTimeline extends StatefulWidget {
  const _ListeningTimeline({
    required this.title,
    required this.events,
  });

  final String title;
  final List<MusicListeningEvent>? events;

  @override
  State<_ListeningTimeline> createState() => _ListeningTimelineState();
}

class _ListeningTimelineState extends State<_ListeningTimeline> {
  bool _showCalendar = false;
  DateTime? _visibleMonth;
  DateTime? _selectedDay;
  DateTime? _calendarFocusDay;

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final material = MaterialLocalizations.of(context);
    final events = widget.events;
    final selectedDay = _selectedDay;
    return Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent(),
      },
      child: AlertDialog(
        title: Text(locals.musicListeningTimeline),
        insetPadding: _showCalendar
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 24)
            : null,
        contentPadding:
            _showCalendar ? const EdgeInsets.fromLTRB(12, 8, 12, 12) : null,
        content: events == null
            ? Text(locals.musicSourceUnavailable)
            : SizedBox(
                width: 420,
                height: (MediaQuery.sizeOf(context).height *
                        (_showCalendar ? .65 : .45))
                    .clamp(0.0, _showCalendar ? 440.0 : 360.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (selectedDay != null)
                          IconButton(
                            tooltip: locals.musicListeningCalendarBack,
                            onPressed: () => setState(() {
                              _calendarFocusDay = _selectedDay;
                              _selectedDay = null;
                            }),
                            icon: const Icon(Icons.arrow_back),
                          ),
                        Expanded(
                          child: Text(
                            selectedDay == null
                                ? widget.title
                                : material.formatFullDate(selectedDay),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (selectedDay == null)
                          IconButton(
                            tooltip: _showCalendar
                                ? locals.musicListeningCalendarShowList
                                : locals.musicListeningCalendarShow,
                            onPressed: () =>
                                setState(() => _showCalendar = !_showCalendar),
                            icon: Icon(_showCalendar
                                ? Icons.list
                                : Icons.calendar_month_outlined),
                          ),
                      ],
                    ),
                    Expanded(
                      child: _buildHistory(locals, events, selectedDay),
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

  Widget _buildHistory(AppLocalizations locals,
      List<MusicListeningEvent> events, DateTime? selectedDay) {
    if (selectedDay != null) {
      final dailyEvents =
          events.where((event) => _listeningDay(event) == selectedDay).toList();
      return dailyEvents.isEmpty
          ? Text(locals.musicListeningCalendarDayEmpty)
          : _TimelineEvents(events: dailyEvents, showDate: false);
    }
    if (events.isEmpty) return Text(locals.musicListeningTimelineEmpty);
    if (!_showCalendar) return _TimelineEvents(events: events);

    // History arrives newest first. Clamp the visible month after deletions.
    final newestDay = _listeningDay(events.first);
    final oldestDay = _listeningDay(events.last);
    final newestMonth = DateTime(newestDay.year, newestDay.month);
    final oldestMonth = DateTime(oldestDay.year, oldestDay.month);
    final requestedMonth = _visibleMonth ?? newestMonth;
    final month = requestedMonth.isBefore(oldestMonth)
        ? oldestMonth
        : requestedMonth.isAfter(newestMonth)
            ? newestMonth
            : requestedMonth;
    return _TimelineCalendar(
      events: events,
      month: month,
      focusDay: _calendarFocusDay,
      onPreviousMonth: month == oldestMonth
          ? null
          : () => setState(
              () => _visibleMonth = DateTime(month.year, month.month - 1)),
      onNextMonth: month == newestMonth
          ? null
          : () => setState(
              () => _visibleMonth = DateTime(month.year, month.month + 1)),
      onDaySelected: (day) => setState(() {
        _visibleMonth = month;
        _selectedDay = day;
      }),
    );
  }
}

DateTime _listeningDay(MusicListeningEvent event) =>
    DateUtils.dateOnly(event.playedAt.toLocal());

class _TimelineCalendar extends StatelessWidget {
  const _TimelineCalendar({
    required this.events,
    required this.month,
    required this.focusDay,
    required this.onPreviousMonth,
    required this.onNextMonth,
    required this.onDaySelected,
  });

  final List<MusicListeningEvent> events;
  final DateTime month;
  final DateTime? focusDay;
  final VoidCallback? onPreviousMonth;
  final VoidCallback? onNextMonth;
  final ValueChanged<DateTime> onDaySelected;

  @override
  Widget build(BuildContext context) {
    final material = MaterialLocalizations.of(context);
    final counts = <int, int>{};
    for (final event in events) {
      final day = _listeningDay(event);
      if (DateUtils.isSameMonth(day, month)) {
        counts.update(day.day, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    final daysInMonth = DateUtils.getDaysInMonth(month.year, month.month);
    final offset = DateUtils.firstDayOffset(month.year, month.month, material);
    final focusedDay =
        isTv && DateUtils.isSameMonth(month, focusDay) ? focusDay?.day : null;
    return SingleChildScrollView(
      key: const PageStorageKey('recording-listening-calendar'),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: material.previousMonthTooltip,
                onPressed: onPreviousMonth,
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Semantics(
                  header: true,
                  liveRegion: true,
                  child: Text(
                    material.formatMonthYear(month),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ),
              IconButton(
                tooltip: material.nextMonthTooltip,
                onPressed: onNextMonth,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          Table(
            children: [
              TableRow(children: [
                for (var column = 0; column < DateTime.daysPerWeek; column++)
                  ExcludeSemantics(
                    child: Text(
                      material.narrowWeekdays[
                          (material.firstDayOfWeekIndex + column) %
                              DateTime.daysPerWeek],
                      textAlign: TextAlign.center,
                    ),
                  ),
              ]),
              for (var start = 1 - offset;
                  start <= daysInMonth;
                  start += DateTime.daysPerWeek)
                TableRow(children: [
                  for (var day = start;
                      day < start + DateTime.daysPerWeek;
                      day++)
                    if (day < 1 || day > daysInMonth)
                      const SizedBox.shrink()
                    else
                      _CalendarDay(
                        date: DateTime(month.year, month.month, day),
                        count: counts[day] ?? 0,
                        autofocus: day == focusedDay,
                        onSelected: onDaySelected,
                      ),
                ]),
            ],
          ),
        ],
      ),
    );
  }
}

class _CalendarDay extends StatelessWidget {
  const _CalendarDay({
    required this.date,
    required this.count,
    required this.autofocus,
    required this.onSelected,
  });

  final DateTime date;
  final int count;
  final bool autofocus;
  final ValueChanged<DateTime> onSelected;

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final material = MaterialLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final hasListens = count > 0;
    final textColor =
        hasListens ? colors.onSecondaryContainer : colors.onSurface;
    final radius = BorderRadius.circular(8);
    return SizedBox(
      height: 52,
      child: Semantics(
        label: locals.musicListeningCalendarDay(
            material.formatFullDate(date), count),
        button: hasListens,
        child: Material(
          color: hasListens ? colors.secondaryContainer : Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            autofocus: autofocus && hasListens,
            onTap: hasListens ? () => onSelected(date) : null,
            focusColor: colors.primary.withValues(alpha: .32),
            child: ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(material.formatDecimal(date.day),
                          style: TextStyle(color: textColor)),
                      if (hasListens)
                        Text(material.formatDecimal(count),
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: textColor)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TimelineEvents extends StatelessWidget {
  const _TimelineEvents({required this.events, this.showDate = true});

  final List<MusicListeningEvent> events;
  final bool showDate;

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
        final time = event.isLegacy
            ? locals.musicListeningTimelineLegacy
            : material.formatTimeOfDay(TimeOfDay.fromDateTime(local),
                alwaysUse24HourFormat: use24Hours);
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
              title: Text(showDate ? material.formatFullDate(local) : time),
              subtitle: showDate ? Text(time) : null,
            ),
          ),
        );
      },
    );
  }
}
