import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/utils.dart' show selectKeys;
import 'package:clipious/utils/views/tv/components/tv_overscan.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../models/music_listening_rankings.dart';
import '../../services/music_listening_history.dart';
import '../components/music_screen_privacy.dart';
import 'music_listening_recap.dart';

class MusicListeningStatisticsPage extends StatefulWidget {
  const MusicListeningStatisticsPage({super.key});

  @override
  State<MusicListeningStatisticsPage> createState() =>
      _MusicListeningStatisticsPageState();
}

class _MusicListeningStatisticsPageState
    extends State<MusicListeningStatisticsPage> {
  late final AppState _session;
  late final MusicListeningHistory _history;
  MusicListeningPeriod _period = MusicListeningPeriod.last30Days;
  MusicListeningRankBy _rankBy = MusicListeningRankBy.song;

  @override
  void initState() {
    super.initState();
    _session = context.read<AppCubit>().state;
    _history = MusicListeningHistory.forProfile(db, _session.profileId);
  }

  @override
  Widget build(BuildContext context) {
    final active = context.select((AppCubit cubit) {
      final state = cubit.state;
      return !state.globalLoading &&
          !state.sessionRecoveryRequired &&
          state.profileId == _session.profileId &&
          state.sessionRevision == _session.sessionRevision &&
          state.server == _session.server;
    });
    final locals = AppLocalizations.of(context)!;
    final available = active && db.profileId == _session.profileId;
    final body = available
        ? ListenableBuilder(
            listenable: _history.changes,
            builder: (context, _) {
              if (db.profileId != _session.profileId) {
                return Center(child: Text(locals.musicListeningUnavailable));
              }
              return _buildRankings(context, locals);
            },
          )
        : Center(child: Text(locals.musicListeningUnavailable));
    final page = Scaffold(
      appBar: AppBar(
        title: Text(locals.musicListeningStatistics),
        actions: [
          IconButton(
            key: const ValueKey('music-listening-recap'),
            tooltip: locals.musicListeningRecap,
            icon: const Icon(Icons.calendar_today_outlined),
            onPressed: available
                ? () => Navigator.of(context).push<void>(MaterialPageRoute(
                    builder: (context) => const MusicScreenPrivacySurface(
                        child: MusicListeningRecapPage())))
                : null,
          ),
        ],
      ),
      body: SafeArea(top: false, child: isTv ? TvOverscan(child: body) : body),
    );
    return Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent(),
      },
      child: page,
    );
  }

  Widget _buildRankings(BuildContext context, AppLocalizations locals) {
    final theme = Theme.of(context);
    final rankings = MusicListeningRankings.fromEvents(
        _history.events(), _period,
        now: DateTime.now());
    final results = rankings.rankedBy(_rankBy);
    final songCount = rankings.rankedBy(MusicListeningRankBy.song).length;
    final paused = _history.recordingPaused;
    final periods = {
      MusicListeningPeriod.last7Days: locals.musicListeningLast7Days,
      MusicListeningPeriod.last30Days: locals.musicListeningLast30Days,
      MusicListeningPeriod.last365Days: locals.musicListeningLast365Days,
      MusicListeningPeriod.allTime: locals.musicListeningAllTime,
    };
    final groups = {
      MusicListeningRankBy.song: locals.musicSongs,
      MusicListeningRankBy.artist: locals.musicListeningArtists,
      MusicListeningRankBy.album: locals.musicListeningAlbums,
      MusicListeningRankBy.playlist: locals.musicPlaylists,
    };
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    for (final period in MusicListeningPeriod.values)
                      ChoiceChip(
                        key: ValueKey(period),
                        label: Text(periods[period]!),
                        selected: _period == period,
                        autofocus:
                            isTv && period == MusicListeningPeriod.last30Days,
                        onSelected: (_) => setState(() => _period = period),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  locals.musicListeningSummary(
                      locals.musicListeningPlayCount(rankings.plays),
                      locals.musicTrackCount(songCount)),
                  style: theme.textTheme.titleMedium,
                ),
                if (paused)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(locals.musicListeningPausedNotice),
                  ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final group in MusicListeningRankBy.values)
                      ChoiceChip(
                        key: ValueKey(group),
                        label: Text(groups[group]!),
                        selected: _rankBy == group,
                        onSelected: (_) => setState(() => _rankBy = group),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (results.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(rankings.plays == 0
                  ? locals.musicListeningEmptyPeriod
                  : locals.musicListeningEmptyRanking),
            ),
          )
        else
          SliverList.builder(
            itemCount: results.length,
            itemBuilder: (context, index) {
              final rank = results[index];
              final tile = ListTile(
                leading: Text(
                    MaterialLocalizations.of(context).formatDecimal(index + 1)),
                title: Text(rank.title ?? locals.musicListeningUnknownTitle),
                subtitle: rank.subtitle == null ? null : Text(rank.subtitle!),
                trailing: Text(locals.musicListeningPlayCount(rank.plays)),
              );
              if (!isTv) return tile;
              return Builder(
                builder: (rowContext) => Focus(
                  onFocusChange: (focused) {
                    if (focused && rowContext.mounted) {
                      Scrollable.ensureVisible(rowContext);
                    }
                  },
                  child: Builder(
                    builder: (context) => ColoredBox(
                      color: Focus.of(context).hasFocus
                          ? theme.colorScheme.secondaryContainer
                          : Colors.transparent,
                      child: tile,
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
