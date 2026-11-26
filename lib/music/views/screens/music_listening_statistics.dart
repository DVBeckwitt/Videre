import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/services/explicit_music_download.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/music/views/screens/music_library.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/tv/screens/tv_player_view.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/views/screens/playlist.dart';
import 'package:clipious/playlists/views/tv/screens/playlist.dart';
import 'package:clipious/utils.dart' show selectKeys;
import 'package:clipious/utils/views/tv/components/tv_overscan.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../models/device_playlist_track.dart';
import '../../models/local_date_interval.dart';
import '../../models/music_listening_rankings.dart';
import '../../models/on_device_music_entry.dart';
import '../../services/local_music_library.dart';
import '../../services/music_listening_history.dart';
import '../components/local_music_folder.dart' show supportsLocalMusicFolders;
import '../components/music_derived_song_selection.dart';
import '../components/music_screen_privacy.dart';
import '../components/music_song_selection_bar.dart';
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
  final _deviceLibrary = LocalMusicLibrary.instance;
  late final _rankChanges =
      Listenable.merge([_history.changes, _deviceLibrary]);
  MusicListeningPeriod _period = MusicListeningPeriod.last30Days;
  DateTimeRange? _customDates;
  MusicListeningRankBy _rankBy = MusicListeningRankBy.song;
  int _actionRevision = 0;

  @override
  void initState() {
    super.initState();
    _session = context.read<AppCubit>().state;
    _history = MusicListeningHistory.forProfile(db, _session.profileId);
    if (supportsLocalMusicFolders && _isCurrent) {
      final deviceIds = _history
          .events()
          .where((event) => event.source == MusicListeningSource.device)
          .map((event) => event.trackId)
          .toSet();
      if (deviceIds.isNotEmpty) {
        unawaited(_deviceLibrary.loadForPlayback(deviceIds));
      }
    }
  }

  bool _matchesSession(AppState state) =>
      !state.globalLoading &&
      !state.sessionRecoveryRequired &&
      state.profileId == _session.profileId &&
      state.sessionRevision == _session.sessionRevision &&
      state.server == _session.server;

  bool get _isCurrent =>
      mounted &&
      db.profileId == _session.profileId &&
      _matchesSession(context.read<AppCubit>().state);

  @override
  Widget build(BuildContext context) {
    final active =
        context.select((AppCubit cubit) => _matchesSession(cubit.state));
    final locals = AppLocalizations.of(context)!;
    final available = active && db.profileId == _session.profileId;
    final body = available
        ? ListenableBuilder(
            listenable: _rankChanges,
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

  Future<void> _openRank(MusicListeningRank rank, MusicListeningTarget target,
      AppLocalizations locals) async {
    if (!_isCurrent || ModalRoute.of(context)?.isCurrent == false) return;
    final revision = ++_actionRevision;
    bool current() => _isCurrent && revision == _actionRevision;
    try {
      final Widget? page;
      switch (target) {
        case ListeningRecording(:final event):
          await _playRecording(event, locals, current);
          return;
        case ListeningArtist(:final channelId):
          page = MusicScreen(artistId: channelId);
        case ListeningAlbum(:final playlistId):
          page = MusicScreen(playlistId: playlistId);
        case ListeningPlaylist(:final reference):
          page = _playlistPage(reference, rank.title ?? locals.musicPlaylists);
      }
      if (!mounted) return;
      if (page case final detail?) {
        await Navigator.of(context)
            .push<void>(MaterialPageRoute(builder: (_) => detail));
      } else {
        _showMessage(locals.musicLibraryActionError);
      }
    } catch (_) {
      if (current()) {
        _showMessage(target is ListeningRecording
            ? locals.musicPlaybackError
            : locals.musicLibraryActionError);
      }
    }
  }

  Future<void> _playRecording(MusicListeningEvent event,
      AppLocalizations locals, bool Function() current) async {
    final queueTitle = locals.musicListeningStatistics;
    switch (event.source) {
      case MusicListeningSource.catalog:
        await MusicScreen.playTracks(context, [event.entry.toVideo()],
            queueTitle: queueTitle);
      case MusicListeningSource.device:
        final library = LocalMusicLibrary.instance;
        await library.loadForPlayback([event.trackId]);
        if (!mounted ||
            !current() ||
            ModalRoute.of(context)?.isCurrent == false) {
          return;
        }
        final selection = library.selectionId;
        final track = library.visibleTrackById(event.trackId);
        if (track == null || !library.acceptsSessionSelection(selection)) {
          _showMessage(locals.musicHistoryPlaybackUnavailable);
          return;
        }
        await MusicScreen.playOnDeviceTracks(
            context, [OnDeviceMusicEntry.device(track)],
            queueTitle: queueTitle,
            isCurrent: () =>
                current() && library.acceptsSessionSelection(selection));
      case MusicListeningSource.download:
        final owner = db.forProfile(_session.profileId);
        final download = event.entry.replayDownload(owner);
        if (download == null) {
          _showMessage(locals.musicHistoryPlaybackUnavailable);
          return;
        }
        if (readyMusicDownload(owner, event.trackId) != null) {
          await MusicScreen.playTracks(
              context,
              [
                event.entry.toVideo().copyWith(
                    explicitMusicDownload: musicDownloadFingerprint(download)),
              ],
              queueTitle: queueTitle);
        } else if (isTv) {
          await Navigator.of(context).push<void>(MaterialPageRoute(
              builder: (_) => TvPlayerScreen.download(
                  download: download, fromMusic: true)));
        } else {
          await context
              .read<PlayerCubit>()
              .playOfflineVideos([download], fromMusic: true);
        }
    }
  }

  Widget? _playlistPage(PlaylistReference source, String title) {
    if (source.profileId != _session.profileId) return null;
    final owner = db.forProfile(_session.profileId);
    final id = source.playlistId;
    if (source.kind == PlaylistSourceKind.local) {
      final exists = service
          .getLocalPlaylists(database: owner)
          .any((playlist) => playlist.isLocal && playlist.playlistId == id);
      return exists ? MusicLibraryPage(source: source) : null;
    }
    if (source.kind == PlaylistSourceKind.account) {
      source.resolveServer(owner);
    } else if (RegExp(r'^(PL|RD|OLAK5uy_)[A-Za-z0-9_-]+$').hasMatch(id)) {
      return MusicScreen(playlistId: id);
    }
    final playlist =
        Playlist(playlistId: id, title: title, author: '', videoCount: 0);
    return isTv
        ? TvPlaylistScreen(
            playlist: playlist, reference: source, canDeleteVideos: false)
        : PlaylistViewScreen(
            playlist: playlist, reference: source, canDeleteVideos: false);
  }

  void _showMessage(String message) {
    if (ModalRoute.of(context)?.isCurrent == false) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickCustomDates(AppLocalizations locals) async {
    if (!_isCurrent) return;
    final today = DateUtils.dateOnly(DateTime.now());
    final current = _customDates;
    final dates = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1900),
      lastDate: today,
      initialDateRange:
          current != null && !current.end.isAfter(today) ? current : null,
      helpText: locals.musicListeningCustomDates,
    );
    if (!mounted || !_isCurrent || dates == null) return;
    setState(() {
      if (_customDates != dates) _actionRevision++;
      _customDates = dates;
    });
  }

  String _customDatesLabel(BuildContext context, AppLocalizations locals) {
    final dates = _customDates;
    if (dates == null) return locals.musicListeningCustomDates;
    final material = MaterialLocalizations.of(context);
    final start = material.formatShortDate(dates.start);
    return DateUtils.isSameDay(dates.start, dates.end)
        ? start
        : locals.musicListeningCustomDateRange(
            start, material.formatShortDate(dates.end));
  }

  Video? _selectionVideo(MusicListeningEvent event) {
    switch (event.source) {
      case MusicListeningSource.catalog:
        return event.entry.toVideo();
      case MusicListeningSource.device:
        final track = _deviceLibrary.visibleTrackById(event.trackId);
        return track == null ? null : devicePlaylistVideo(track);
      case MusicListeningSource.download:
        final owner = db.forProfile(_session.profileId);
        final download = event.entry.replayDownload(owner);
        if (download == null) return null;
        final fingerprint = musicDownloadFingerprint(download);
        if (readyMusicDownload(owner, event.trackId,
                fingerprint: fingerprint) ==
            null) {
          return null;
        }
        return event.entry
            .toVideo()
            .copyWith(explicitMusicDownload: fingerprint);
    }
  }

  Widget _buildRankings(BuildContext context, AppLocalizations locals) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final events = _history.events();
    final dates = _customDates;
    final rankings = dates == null
        ? MusicListeningRankings.fromEvents(events, _period, now: now)
        : MusicListeningRankings.fromDateInterval(
            events, LocalDateInterval.inclusive(dates.start, dates.end),
            now: now);
    final results = rankings.rankedBy(_rankBy);
    final songCount = rankings.rankedBy(MusicListeningRankBy.song).length;
    final paused = _history.recordingPaused;
    final periods = {
      MusicListeningPeriod.last7Days: locals.musicListeningLast7Days,
      MusicListeningPeriod.last30Days: locals.musicListeningLast30Days,
      MusicListeningPeriod.last90Days: locals.musicListeningLast3Months,
      MusicListeningPeriod.last180Days: locals.musicListeningLast6Months,
      MusicListeningPeriod.last365Days: locals.musicListeningLast365Days,
      MusicListeningPeriod.allTime: locals.musicListeningAllTime,
    };
    final groups = {
      MusicListeningRankBy.song: locals.musicSongs,
      MusicListeningRankBy.artist: locals.musicListeningArtists,
      MusicListeningRankBy.album: locals.musicListeningAlbums,
      MusicListeningRankBy.playlist: locals.musicPlaylists,
    };
    final recordings = {
      for (final rank in results)
        if (rank.target case ListeningRecording(:final event)) event.id: event,
    };
    final selectable = {
      for (final event in recordings.values) event.id: _selectionVideo(event),
    };
    List<OnDeviceMusicEntry>? resolveDeviceSongs(List<String> ids) {
      final resolved = [
        for (final id in ids)
          if (recordings[id]
              case MusicListeningEvent(
                source: MusicListeningSource.device,
                :final trackId
              ))
            if (_deviceLibrary.visibleTrackById(trackId) case final track?)
              OnDeviceMusicEntry.device(track),
      ];
      return resolved.length == ids.length ? resolved : null;
    }

    return MusicDerivedSongSelection(
      key: ValueKey((_period, dates, _rankBy)),
      songs: selectable,
      isCurrent: () => _isCurrent,
      deviceLibrary: _deviceLibrary,
      resolveOnDevice: resolveDeviceSongs,
      builder: (context, selection) => CustomScrollView(
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
                          selected: dates == null && _period == period,
                          autofocus:
                              isTv && period == MusicListeningPeriod.last30Days,
                          onSelected: (_) => setState(() {
                            if (_period != period || _customDates != null) {
                              _actionRevision++;
                            }
                            _period = period;
                            _customDates = null;
                          }),
                        ),
                      ChoiceChip(
                        key: const ValueKey('music-listening-custom-dates'),
                        label: Text(_customDatesLabel(context, locals)),
                        tooltip: locals.musicListeningCustomDates,
                        selected: dates != null,
                        onSelected: (_) => _pickCustomDates(locals),
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
                          onSelected: (_) => setState(() {
                            if (_rankBy != group) _actionRevision++;
                            _rankBy = group;
                          }),
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
                final target = rank.target;
                final id =
                    target is ListeningRecording ? target.event.id : null;
                final canSelect = id != null && selectable.containsKey(id);
                final tile = ListTile(
                  selected: canSelect && selection.selected(id) == true,
                  onLongPress: canSelect ? () => selection.start(id) : null,
                  onTap: selection.active
                      ? canSelect
                          ? () => selection.toggle(id)
                          : null
                      : target == null
                          ? null
                          : () => _openRank(rank, target, locals),
                  leading: Text(MaterialLocalizations.of(context)
                      .formatDecimal(index + 1)),
                  title: Text(rank.title ?? locals.musicListeningUnknownTitle),
                  subtitle: rank.subtitle == null ? null : Text(rank.subtitle!),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(locals.musicListeningPlayCount(rank.plays)),
                      if (canSelect)
                        MusicSongSelectButton(
                          selected: selection.selected(id),
                          onPressed: () => selection.toggle(id),
                        )
                      else if (target != null) ...[
                        const SizedBox(width: 8),
                        Icon(target is ListeningRecording
                            ? Icons.play_arrow
                            : Icons.chevron_right),
                      ],
                    ],
                  ),
                );
                if (!isTv) return tile;
                return Builder(
                  builder: (rowContext) => Focus(
                    canRequestFocus: target == null,
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
      ),
    );
  }
}
