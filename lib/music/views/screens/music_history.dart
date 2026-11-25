import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/explicit_music_download.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/music_search_text.dart';
import 'package:clipious/music/models/on_device_music_entry.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/music_listening_history.dart';
import 'package:clipious/music/views/components/music_history_privacy.dart';
import 'package:clipious/music/views/components/music_history_transfer.dart';
import 'package:clipious/music/views/components/music_listening_timeline.dart';
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

enum _HistoryAction {
  play,
  shuffle,
  remove,
  clear,
  timeline,
  privacy,
  transfer
}

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
  Set<String>? _selection;
  bool _finding = false;
  bool _removing = false;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppCubit>();
    _session = _app.state;
    _database = db;
    _owner = _database.forProfile(_session.profileId);
    _history = MusicListeningHistory.forProfile(_database, _owner.profileId);
    _rows = _readRows();
    _history.changes.addListener(_reload);
  }

  Map<String, _HistoryRow> _readRows() {
    // The service emits newest first. Each row represents one exact track
    // identity, while the timeline retains all its separate listening events.
    final rows = <String, _HistoryRow>{};
    for (final event in _history.events()) {
      rows.putIfAbsent(event.trackId, () => _HistoryRow(event));
    }
    return rows;
  }

  void _reload() {
    if (!_sameSession(_app.state)) return;
    setState(() {
      _rows = _readRows();
      _selection?.retainAll(_rows.keys);
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

  void _startSelection([String? id]) {
    setState(() => _selection = {if (id != null) id});
    _focusAfterLayout(_exitSelectionFocus);
  }

  void _closeSelection() {
    setState(() => _selection = null);
    _focusAfterLayout(_selectFocus);
  }

  void _toggleSelection(String id) {
    setState(() {
      final selection = _selection!;
      if (!selection.add(id)) selection.remove(id);
    });
  }

  void _showMessage(String message) {
    if (_current) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _confirmRemoval({Set<String>? ids}) async {
    if (!_current || _removing || ids?.isEmpty == true) return;
    final locals = AppLocalizations.of(context)!;
    final approved = ids == null ? null : Set<String>.unmodifiable(ids);
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (context) => AlertDialog(
        title: Text(approved == null
            ? locals.clearHistoryQuestion
            : locals.musicHistoryRemove),
        content: Text(approved == null
            ? locals.clearMusicPlaybackHistory
            : locals.musicHistoryRemoveConfirm(approved.length)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(locals.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(approved == null ? locals.ok : locals.delete)),
        ],
      ),
    );
    if (confirmed != true || !_current || _removing) return;
    setState(() => _removing = true);
    try {
      if (approved == null) {
        await _history.clear();
      } else {
        await _history.removeTracks(approved);
      }
      if (_current && _selection?.isEmpty == true) _closeSelection();
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
    final locals = AppLocalizations.of(context)!;
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
        _sameSession(_app.state) &&
        rows.every((row) => _rows[row.id]?.event.id == row.event.id);
    if (!rowsCurrent()) return;
    if (shuffle) rows = List.of(rows)..shuffle();

    try {
      if (rows.first.isDevice) {
        final library = LocalMusicLibrary.instance;
        await library.loadForPlayback(rows.map((row) => row.id));
        if (!mounted || !_current || !rowsCurrent()) return;
        final entries = [
          for (final row in rows)
            if (library.visibleTrackById(row.id) case final track?)
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
                _sameSession(_app.state) &&
                library.acceptsSessionSelection(choice));
        return;
      }

      final videos = <Video>[];
      for (final row in rows) {
        final entry = row.event.entry;
        final video = entry.toVideo();
        if (row.event.source != MusicListeningSource.download) {
          videos.add(video);
          continue;
        }
        final download = entry.replayDownload(_owner);
        if (download != null && readyMusicDownload(_owner, row.id) != null) {
          videos.add(video.copyWith(
              explicitMusicDownload: musicDownloadFingerprint(download)));
        } else if (download != null && rows.length == 1) {
          await _playLegacyDownload(download);
          return;
        } else {
          _showMessage(locals.musicHistoryPlaybackUnavailable);
          return;
        }
      }
      await MusicScreen.playTracks(context, videos,
          queueTitle: locals.musicPlaybackHistory);
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
    final selection = _selection;
    if (selection == null) {
      return Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        IconButton(
            tooltip: locals.musicPlayAll,
            icon: const Icon(Icons.play_arrow),
            onPressed: visible.isEmpty ? null : () => _play(visible)),
        IconButton(
            tooltip: locals.musicShuffleAll,
            icon: const Icon(Icons.shuffle),
            onPressed:
                visible.isEmpty ? null : () => _play(visible, shuffle: true)),
        IconButton(
            focusNode: _selectFocus,
            tooltip: locals.musicQueueSelect,
            icon: const Icon(Icons.checklist_rounded),
            onPressed: visible.isEmpty ? null : _startSelection),
      ]);
    }
    final selected =
        visible.where((row) => selection.contains(row.id)).toList();
    final allSelected = visible.isNotEmpty && selected.length == visible.length;
    return Row(children: [
      IconButton(
          focusNode: _exitSelectionFocus,
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          icon: const Icon(Icons.close),
          onPressed: _closeSelection),
      Expanded(
        child: Text(locals.musicQueueSelected(selected.length),
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      IconButton(
        tooltip: allSelected
            ? locals.musicQueueDeselectAll
            : locals.musicQueueSelectAll,
        icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
        onPressed: visible.isEmpty
            ? null
            : () => setState(() {
                  final ids = visible.map((row) => row.id);
                  allSelected
                      ? selection.removeAll(ids)
                      : selection.addAll(ids);
                }),
      ),
      PopupMenuButton<_HistoryAction>(
        tooltip: locals.musicPlaylistSelectionActions,
        enabled: selected.isNotEmpty && !_removing,
        onSelected: (action) {
          switch (action) {
            case _HistoryAction.play:
            case _HistoryAction.shuffle:
              unawaited(
                  _play(selected, shuffle: action == _HistoryAction.shuffle));
            case _HistoryAction.remove:
              unawaited(
                  _confirmRemoval(ids: selected.map((row) => row.id).toSet()));
            default:
              break;
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
              value: _HistoryAction.play, child: Text(locals.musicPlay)),
          PopupMenuItem(
              value: _HistoryAction.shuffle, child: Text(locals.musicShuffle)),
          PopupMenuItem(
              value: _HistoryAction.remove,
              child: Text(locals.musicHistoryRemove)),
        ],
      ),
    ]);
  }

  Widget _row(_HistoryRow row, AppLocalizations locals) {
    final selected = _selection?.contains(row.id);
    final date = MaterialLocalizations.of(context)
        .formatCompactDate(row.event.playedAt.toLocal());
    return ListTile(
      key: ValueKey(row.id),
      selected: selected ?? false,
      leading: Icon(selected == null
          ? Icons.music_note_outlined
          : selected
              ? Icons.check_box
              : Icons.check_box_outline_blank),
      title: Text(row.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
          [row.artist, row.album, date]
              .nonNulls
              .where((value) => value.trim().isNotEmpty)
              .join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis),
      onTap: selected == null
          ? () => _play([row])
          : () => _toggleSelection(row.id),
      onLongPress: selected == null ? () => _startSelection(row.id) : null,
      trailing: selected != null
          ? null
          : PopupMenuButton<_HistoryAction>(
              onSelected: (action) {
                if (!_current || !_rows.containsKey(row.id)) return;
                if (action == _HistoryAction.timeline) {
                  unawaited(showMusicListeningTimeline(context,
                      trackId: row.id, title: row.title));
                } else {
                  unawaited(_confirmRemoval(ids: {row.id}));
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                    value: _HistoryAction.timeline,
                    child: Text(locals.musicListeningTimeline)),
                PopupMenuItem(
                    enabled: !_removing,
                    value: _HistoryAction.remove,
                    child: Text(locals.musicHistoryRemove)),
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final material = MaterialLocalizations.of(context);
    final valid = context.select((AppCubit app) => _sameSession(app.state));
    final terms = musicSearchTerms(_query.text);
    final visible = [
      if (valid)
        for (final row in _rows.values)
          if (terms.every(row.searchText.contains)) row,
    ];
    final positions = {
      for (final (index, row) in visible.indexed) ValueKey(row.id): index,
    };
    final body = Column(children: [
      if (_finding && _selection == null) _queryField(locals),
      if (_rows.isNotEmpty || _selection != null) _toolbar(visible, locals),
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
                itemBuilder: (context, index) => _row(visible[index], locals),
              ),
      ),
    ]);
    return PopScope(
      canPop: !valid || (!_finding && _selection == null),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selection != null) {
          _closeSelection();
        } else if (_finding) {
          _toggleFind();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(locals.musicPlaybackHistory),
          actions: [
            if (valid && _selection == null)
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
            if (valid && _selection == null)
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
