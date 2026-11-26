import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/explicit_music_download.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/device_playlist_track.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/music_search_text.dart';
import 'package:clipious/music/models/music_song_selection.dart';
import 'package:clipious/music/models/on_device_music_entry.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/music_listening_history.dart';
import 'package:clipious/music/views/components/music_history_privacy.dart';
import 'package:clipious/music/views/components/music_history_transfer.dart';
import 'package:clipious/music/views/components/music_listening_timeline.dart';
import 'package:clipious/music/views/components/music_song_selection_bar.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/tv/screens/tv_player_view.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/utils/views/tv/components/tv_overscan.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'music.dart';

enum _HistoryAction { select, remove, clear, timeline, privacy, transfer }

enum _PlaybackGroup { catalogAndDownloads, deviceFiles }

class _HistoryRow {
  _HistoryRow(this.event)
      : title = event.entry.musicMetadata?.title.trim().isNotEmpty == true
            ? event.entry.musicMetadata!.title
            : event.entry.title;

  final MusicListeningEvent event;
  final String title;
  String get id => event.trackId;
  bool get isDevice => isLocalMusicPlaybackId(id);
  String? get artist =>
      event.entry.musicMetadata?.artist.trim().isNotEmpty == true
          ? event.entry.musicMetadata!.artist
          : event.entry.author;
  String? get album => event.entry.musicMetadata?.album;
  DateTime get localPlayedAt => event.playedAt.toLocal();
  late final String searchText =
      normalizeMusicSearchText([title, artist, album].nonNulls.join(' '));
}

class MusicHistoryScreen extends StatefulWidget {
  const MusicHistoryScreen({super.key});

  @override
  State<MusicHistoryScreen> createState() => _MusicHistoryScreenState();
}

class _MusicHistoryScreenState extends State<MusicHistoryScreen> {
  final _query = TextEditingController();
  final _queryFocus = FocusNode();
  final _findFocus = FocusNode();
  final _selectFocus = FocusNode();
  final _exitSelectionFocus = FocusNode();
  final _scroll = ScrollController();
  late final AppCubit _app;
  late final AppState _session;
  late final IDbClient _database;
  late final IDbClient _owner;
  late final MusicListeningHistory _history;
  late Map<String, _HistoryRow> _rows;
  late Map<String, _HistoryRow> _listens;
  final _selection = MusicSongSelection<String>();
  bool _everyListen = false;
  bool _finding = false;
  bool _removing = false;
  int _replayRequest = 0;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppCubit>();
    _session = _app.state;
    _database = db;
    _owner = _database.forProfile(_session.profileId);
    _history = MusicListeningHistory.forProfile(_database, _owner.profileId);
    _readRows();
    _history.changes.addListener(_reload);
  }

  void _readRows() {
    _rows = {};
    _listens = {};
    // Both views follow the service's newest-first order.
    for (final event in _history.events()) {
      final row = _HistoryRow(event);
      _listens[event.id] = row;
      _rows.putIfAbsent(event.trackId, () => row);
    }
  }

  void _reload() {
    if (!_sameSession(_app.state)) return;
    setState(() {
      _readRows();
      _selection.retain((_everyListen ? _listens : _rows).keys);
    });
  }

  @override
  void dispose() {
    _history.changes.removeListener(_reload);
    _query.dispose();
    _queryFocus.dispose();
    _findFocus.dispose();
    _selectFocus.dispose();
    _exitSelectionFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _sameSession(AppState state) =>
      !_app.isClosed &&
      identical(db, _database) &&
      _database.profileId == _owner.profileId &&
      state.profileId == _session.profileId &&
      state.sessionRevision == _session.sessionRevision &&
      state.server == _session.server &&
      !state.globalLoading &&
      !state.sessionRecoveryRequired;

  bool get _current =>
      mounted &&
      _sameSession(_app.state) &&
      ModalRoute.of(context)?.isCurrent != false;

  void _focusAfterLayout(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current && node.context != null) node.requestFocus();
    });
  }

  void _queryChanged() {
    setState(() {});
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _toggleFind() {
    setState(() {
      _finding = !_finding;
      if (!_finding) _query.clear();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _focusAfterLayout(_finding ? _queryFocus : _findFocus);
  }

  void _showEveryListen(bool value) {
    if (value == _everyListen) return;
    setState(() => _everyListen = value);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  String _rowId(_HistoryRow row) => _everyListen ? row.event.id : row.id;

  void _startSelection([String? id]) {
    setState(() {
      if (id == null) {
        _selection.begin();
      } else {
        _selection.start(id);
      }
    });
    _focusAfterLayout(_exitSelectionFocus);
  }

  void _closeSelection() {
    setState(_selection.clear);
    _focusAfterLayout(_selectFocus);
  }

  void _showMessage(String message) {
    if (_current) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _confirmRemoval({List<_HistoryRow>? rows}) async {
    if (!_current || _removing || rows?.isEmpty == true) return;
    final locals = AppLocalizations.of(context)!;
    final everyListen = _everyListen;
    final removalLabel = everyListen
        ? locals.musicHistoryRemoveListens
        : locals.musicHistoryRemove;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (context) => AlertDialog(
        title: Text(rows == null ? locals.clearHistoryQuestion : removalLabel),
        content: Text(rows == null
            ? locals.clearMusicPlaybackHistory
            : everyListen
                ? locals.musicHistoryRemoveListensConfirm(rows.length)
                : locals.musicHistoryRemoveConfirm(rows.length)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(locals.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(rows == null ? locals.ok : locals.delete)),
        ],
      ),
    );
    if (confirmed != true ||
        !_current ||
        _removing ||
        everyListen != _everyListen) {
      return;
    }
    setState(() => _removing = true);
    try {
      if (rows == null) {
        await _history.clear();
      } else if (everyListen) {
        await _history.removeEvents(rows.map((row) => row.event));
      } else {
        await _history.removeTracks(rows.map((row) => row.id).toSet());
      }
      final remaining = (_everyListen ? _listens : _rows).keys;
      if (_current &&
          _selection.active &&
          !remaining.any(_selection.contains)) {
        _closeSelection();
      }
    } catch (_) {
      _showMessage(locals.itemlistErrorGeneric);
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  Future<_PlaybackGroup?> _chooseGroup(AppLocalizations locals) =>
      showDialog<_PlaybackGroup>(
        context: context,
        useRootNavigator: false,
        animationStyle: AppMotion.dialogStyle(context),
        builder: (context) => SimpleDialog(
          title: Text(locals.musicHistoryChoosePlaybackSource),
          children: [
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.pop(context, _PlaybackGroup.catalogAndDownloads),
              child: Text(locals.musicHistoryCatalogAndDownloads),
            ),
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.pop(context, _PlaybackGroup.deviceFiles),
              child: Text(locals.musicHistoryDeviceFiles),
            ),
          ],
        ),
      );

  Future<void> _play(List<_HistoryRow> rows, {bool shuffle = false}) async {
    if (!_current || rows.isEmpty) return;
    final request = ++_replayRequest;
    final locals = AppLocalizations.of(context)!;
    final everyListen = _everyListen;
    final hasDevice = rows.any((row) => row.isDevice);
    final hasCatalog = rows.any((row) => !row.isDevice);
    if (hasDevice && hasCatalog) {
      final group = await _chooseGroup(locals);
      if (!mounted || !_current || group == null) return;
      rows = rows
          .where((row) => row.isDevice == (group == _PlaybackGroup.deviceFiles))
          .toList();
    }
    // A refreshed row can represent a different source for the same song.
    // Recheck the exact event approved by this action across asynchronous work.
    bool rowsCurrent() =>
        mounted &&
        _replayRequest == request &&
        _sameSession(_app.state) &&
        everyListen == _everyListen &&
        rows.every((row) => everyListen
            ? _listens.containsKey(row.event.id)
            : _rows[row.id]?.event.id == row.event.id);
    if (!rowsCurrent()) return;
    if (shuffle) rows = List.of(rows)..shuffle();

    try {
      if (rows.first.isDevice) {
        final library = LocalMusicLibrary.instance;
        await library.loadForPlayback(rows.map((row) => row.id));
        if (!mounted || !_current || !rowsCurrent()) return;
        final entries = [
          for (final row in rows)
            if (_visibleDeviceTrack(library, row.id) case final track?)
              OnDeviceMusicEntry.device(track),
        ];
        if (entries.length != rows.length) {
          _showMessage(locals.musicHistoryPlaybackUnavailable);
          return;
        }
        final choice = library.selectionId;
        await MusicScreen.playOnDeviceTracks(context, entries,
            queueTitle: locals.musicPlaybackHistory,
            isCurrent: () =>
                mounted &&
                _replayRequest == request &&
                _sameSession(_app.state) &&
                library.acceptsSessionSelection(choice));
        return;
      }

      final videos = <Video>[];
      for (final row in rows) {
        final video = _historyVideo(row);
        if (video != null) {
          videos.add(video);
          continue;
        }
        final download = row.event.entry.replayDownload(_owner);
        if (download != null && rows.length == 1) {
          await _playLegacyDownload(download);
          return;
        }
        _showMessage(locals.musicHistoryPlaybackUnavailable);
        return;
      }
      await MusicScreen.playTracks(context, videos,
          queueTitle: locals.musicPlaybackHistory);
    } catch (_) {
      _showMessage(locals.musicPlaybackError);
    }
  }

  LocalMusicTrack? _visibleDeviceTrack(LocalMusicLibrary library, String id) =>
      library.visibleTrackById(id) ??
      library.playlistTrackById(id, visibleOnly: true);

  Video? _historyVideo(_HistoryRow row) {
    final entry = row.event.entry;
    if (row.event.source != MusicListeningSource.download) {
      return entry.toVideo();
    }
    final download = entry.replayDownload(_owner);
    if (download == null || readyMusicDownload(_owner, row.id) == null) {
      return null;
    }
    return entry
        .toVideo()
        .copyWith(explicitMusicDownload: musicDownloadFingerprint(download));
  }

  Future<void> _replayFrom(_HistoryRow selected, List<_HistoryRow> rows) async {
    if (!_current) return;
    final request = ++_replayRequest;
    final locals = AppLocalizations.of(context)!;
    bool rowsCurrent() =>
        mounted &&
        _replayRequest == request &&
        _sameSession(_app.state) &&
        rows.every((row) => _listens.containsKey(row.event.id));
    if (!rowsCurrent()) return;

    try {
      final library = LocalMusicLibrary.instance;
      final deviceIds = rows.where((row) => row.isDevice).map((row) => row.id);
      final hasDevice = deviceIds.isNotEmpty;
      if (hasDevice) {
        await library.loadForPlayback(deviceIds);
        if (!_current || !rowsCurrent()) return;
      }
      Video? playableVideo(_HistoryRow row) {
        if (!row.isDevice) return _historyVideo(row);
        final track = _visibleDeviceTrack(library, row.id);
        return track == null ? null : devicePlaylistVideo(track);
      }

      // A missing source can be skipped elsewhere in the queue. The tapped
      // occurrence must resolve on its own before playback can start.
      final queue = [
        for (final row in rows)
          if (playableVideo(row) case final video?)
            (eventId: row.event.id, video: video),
      ];
      final startIndex =
          queue.indexWhere((entry) => entry.eventId == selected.event.id);
      if (startIndex < 0) {
        final download = selected.event.entry.replayDownload(_owner);
        if (download != null) {
          await _playLegacyDownload(download);
        } else {
          _showMessage(locals.musicHistoryPlaybackUnavailable);
        }
        return;
      }
      if (!mounted) return;
      final videos = [for (final entry in queue) entry.video];
      final queuedDeviceIds = videos
          .map((video) => video.videoId)
          .where(isLocalMusicPlaybackId)
          .toSet();
      final librarySelection = library.selectionId;
      bool devicesCurrent() =>
          queuedDeviceIds.isEmpty ||
          (library.acceptsSessionSelection(librarySelection) &&
              queuedDeviceIds.every((id) =>
                  library.playlistTrackById(id, visibleOnly: true) != null));
      await MusicScreen.playCollectionTracks(context, videos,
          queueTitle: locals.musicPlaybackHistory,
          startIndex: startIndex,
          isCurrent: () => rowsCurrent() && devicesCurrent());
    } catch (_) {
      _showMessage(locals.musicPlaybackError);
    }
  }

  Future<void> _playLegacyDownload(DownloadedVideo download) => isTv
      ? Navigator.of(context).push<void>(MaterialPageRoute(
          builder: (_) =>
              TvPlayerScreen.download(download: download, fromMusic: true)))
      : context
          .read<PlayerCubit>()
          .playOfflineVideos([download], fromMusic: true);

  Widget _queryField(AppLocalizations locals) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 4),
        child: TextField(
          key: const ValueKey('music-history-query'),
          controller: _query,
          focusNode: _queryFocus,
          onChanged: (_) => _queryChanged(),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            labelText: locals.musicHistoryFind,
            isDense: true,
            suffixIcon: _query.text.isEmpty
                ? null
                : IconButton(
                    tooltip:
                        MaterialLocalizations.of(context).clearButtonTooltip,
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _query.clear();
                      _queryChanged();
                      _queryFocus.requestFocus();
                    },
                  ),
          ),
        ),
      );

  Widget _toolbar(List<_HistoryRow> visible, AppLocalizations locals) {
    if (!_selection.active) {
      return Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        if (!_everyListen) ...[
          IconButton(
              tooltip: locals.musicPlayAll,
              icon: const Icon(Icons.play_arrow),
              onPressed: visible.isEmpty ? null : () => _play(visible)),
          IconButton(
              tooltip: locals.musicShuffleAll,
              icon: const Icon(Icons.shuffle),
              onPressed:
                  visible.isEmpty ? null : () => _play(visible, shuffle: true)),
        ],
        IconButton(
            focusNode: _selectFocus,
            tooltip: locals.musicQueueSelect,
            icon: const Icon(Icons.checklist_rounded),
            onPressed: visible.isEmpty ? null : _startSelection),
      ]);
    }

    final everyListen = _everyListen;
    final visibleIds = visible.map(_rowId);
    final selected = _selection.selectedRows(visible, _rowId);
    final byEventId = {for (final row in selected) row.event.id: row};
    final videos = [
      for (final row in selected)
        if (_selectionVideo(row) case final video?)
          video.copyWith(queueEntryId: row.event.id),
    ];
    bool current() =>
        mounted &&
        _sameSession(_app.state) &&
        everyListen == _everyListen &&
        _selection.active &&
        selected.every((row) =>
            _selection.contains(_rowId(row)) &&
            (everyListen
                ? _listens.containsKey(row.event.id)
                : _rows[row.id]?.event.id == row.event.id));

    List<OnDeviceMusicEntry>? resolveOnDevice() {
      if (!current() || selected.any((row) => !row.isDevice)) return null;
      final library = LocalMusicLibrary.instance;
      final tracks = [
        for (final row in selected)
          if (_visibleDeviceTrack(library, row.id) case final track?)
            OnDeviceMusicEntry.device(track),
      ];
      return tracks.length == selected.length ? tracks : null;
    }

    return MusicSongSelectionBar(
      selected: videos,
      selectedCount: selected.length,
      allSelected: _selection.allSelected(visibleIds),
      onToggleAll: visible.isEmpty
          ? null
          : () => setState(() => _selection.toggleAll(visibleIds)),
      onClose: _closeSelection,
      closeFocus: _exitSelectionFocus,
      isCurrent: current,
      resolveOnDevice: resolveOnDevice,
      closeOnPlay: false,
      onPlay: (tracks) => _play([
        for (final track in tracks) byEventId[track.queueEntryId]!,
      ]),
      removal: selected.isEmpty || _removing
          ? null
          : (
              label: everyListen
                  ? locals.musicHistoryRemoveListens
                  : locals.musicHistoryRemove,
              run: () => _confirmRemoval(rows: selected),
            ),
    );
  }

  Video? _selectionVideo(_HistoryRow row) {
    if (!row.isDevice) return _historyVideo(row);
    final track = _visibleDeviceTrack(LocalMusicLibrary.instance, row.id);
    return track == null ? null : devicePlaylistVideo(track);
  }

  Widget _row(_HistoryRow row, AppLocalizations locals,
      {VoidCallback? replay}) {
    final id = _rowId(row);
    final selected = _selection.contains(id);
    final material = MaterialLocalizations.of(context);
    final timestamp = replay == null
        ? material.formatCompactDate(row.localPlayedAt)
        : material.formatTimeOfDay(TimeOfDay.fromDateTime(row.localPlayedAt),
            alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));
    return ListTile(
      key: replay == null ? ValueKey(row.id) : null,
      selected: selected,
      leading: _selection.active
          ? MusicSongSelectButton(
              selected: selected,
              onPressed: () => setState(() => _selection.toggle(id)),
            )
          : const Icon(Icons.music_note_outlined),
      title: Text(row.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
          [row.artist, row.album, timestamp]
              .nonNulls
              .where((value) => value.trim().isNotEmpty)
              .join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis),
      onTap: _selection.active
          ? () => setState(() => _selection.toggle(id))
          : replay ?? () => _play([row]),
      onLongPress: _selection.active ? null : () => _startSelection(id),
      trailing: _selection.active
          ? null
          : PopupMenuButton<_HistoryAction>(
              onSelected: (action) {
                if (!_current ||
                    !(_everyListen ? _listens : _rows).containsKey(id)) {
                  return;
                }
                switch (action) {
                  case _HistoryAction.select:
                    _startSelection(id);
                  case _HistoryAction.timeline:
                    unawaited(showMusicListeningTimeline(context,
                        trackId: row.id, title: row.title));
                  case _HistoryAction.remove:
                    unawaited(_confirmRemoval(rows: [row]));
                  default:
                    break;
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                    value: _HistoryAction.select,
                    child: Text(locals.musicSelectSong)),
                PopupMenuItem(
                    value: _HistoryAction.timeline,
                    child: Text(locals.musicListeningTimeline)),
                PopupMenuItem(
                    enabled: !_removing,
                    value: _HistoryAction.remove,
                    child: Text(_everyListen
                        ? locals.musicHistoryRemoveListens
                        : locals.musicHistoryRemove)),
              ],
            ),
    );
  }

  Widget _listenRow(
      List<_HistoryRow> visible, int index, AppLocalizations locals) {
    final row = visible[index];
    final startsDay = index == 0 ||
        !DateUtils.isSameDay(
            visible[index - 1].localPlayedAt, row.localPlayedAt);
    return Column(
      key: ValueKey(row.event.id),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (startsDay)
          Semantics(
            header: true,
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 4),
              child: Text(
                MaterialLocalizations.of(context)
                    .formatFullDate(row.localPlayedAt),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ),
        _row(row, locals, replay: () => _replayFrom(row, visible)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final material = MaterialLocalizations.of(context);
    final valid = context.select((AppCubit app) => _sameSession(app.state));
    if (!valid) _selection.clear();
    final terms = musicSearchTerms(_query.text);
    final visible = [
      if (valid)
        for (final row in (_everyListen ? _listens : _rows).values)
          if (terms.every(row.searchText.contains)) row,
    ];
    final positions = {
      for (final (index, row) in visible.indexed) ValueKey(_rowId(row)): index,
    };
    final body = Column(children: [
      if (!_selection.active)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, children: [
            ChoiceChip(
              label: Text(locals.musicSongs),
              selected: !_everyListen,
              onSelected: (_) => _showEveryListen(false),
            ),
            ChoiceChip(
              label: Text(locals.musicHistoryEveryListen),
              selected: _everyListen,
              onSelected: (_) => _showEveryListen(true),
            ),
          ]),
        ),
      if (_finding && !_selection.active) _queryField(locals),
      if (visible.isNotEmpty || _selection.active) _toolbar(visible, locals),
      Expanded(
        child: visible.isEmpty
            ? Center(
                child: Text(
                    terms.isEmpty
                        ? locals.noMusicPlaybackHistory
                        : locals.musicNoResults,
                    textAlign: TextAlign.center))
            : ListView.builder(
                controller: _scroll,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                itemCount: visible.length,
                findChildIndexCallback: (key) => positions[key],
                itemBuilder: (context, index) => _everyListen
                    ? _listenRow(visible, index, locals)
                    : _row(visible[index], locals),
              ),
      ),
    ]);
    return PopScope(
      canPop: !valid || (!_finding && !_selection.active),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selection.active) {
          _closeSelection();
        } else if (_finding) {
          _toggleFind();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(locals.musicPlaybackHistory),
          actions: [
            if (valid && !_selection.active)
              IconButton(
                key: const ValueKey('music-history-find'),
                autofocus: isTv,
                focusNode: _findFocus,
                tooltip: _finding
                    ? material.closeButtonTooltip
                    : locals.musicHistoryFind,
                icon: Icon(_finding ? Icons.close : Icons.search),
                onPressed: _toggleFind,
              ),
            if (valid && !_selection.active)
              PopupMenuButton<_HistoryAction>(
                key: const ValueKey('music-history-more'),
                onSelected: (action) {
                  if (!_current) return;
                  switch (action) {
                    case _HistoryAction.privacy:
                      unawaited(showMusicHistoryPrivacy(context));
                    case _HistoryAction.transfer:
                      unawaited(showMusicHistoryTransfer(context));
                    case _HistoryAction.clear:
                      unawaited(_confirmRemoval());
                    default:
                      break;
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                      value: _HistoryAction.privacy,
                      child: Text(locals.musicHistoryPrivacy)),
                  PopupMenuItem(
                      value: _HistoryAction.transfer,
                      child: Text(locals.musicHistoryTransfer)),
                  PopupMenuItem(
                      enabled: _rows.isNotEmpty && !_removing,
                      value: _HistoryAction.clear,
                      child: Text(locals.clearHistoryQuestion)),
                ],
              ),
          ],
        ),
        body: valid
            ? SafeArea(child: isTv ? TvOverscan(child: body) : body)
            : null,
      ),
    );
  }
}
