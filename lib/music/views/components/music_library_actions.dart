import 'dart:async';
import 'dart:ui' show SemanticsRole;

import 'package:clipious/app/states/app.dart';
import 'package:clipious/content_filter/community_models.dart'
    show normalizeChannelId;
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/music_offline_policy.dart';
import 'package:clipious/downloads/services/download_playback_source.dart';
import 'package:clipious/downloads/services/download_storage.dart';
import 'package:clipious/downloads/services/explicit_music_download.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/deleted_music_playlist.dart';
import 'package:clipious/music/models/device_playlist_track.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_song_row_swipe_action.dart';
import 'package:clipious/music/models/on_device_music_entry.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/local_music_video_pairings.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/music/services/music_passage_bookmarks.dart';
import 'package:clipious/music/services/music_song_radio.dart';
import 'package:clipious/music/services/music_visibility.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/models/playback_session.dart'
    show normalizedQueueTitle;
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/service.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils.dart' show showSharingSheet;
import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/videos/views/components/download_modal_sheet.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';

import '../screens/music.dart';
import 'local_music_folder.dart' show renameLocalMusicTrack;
import 'local_music_video_pairing_dialog.dart';
import '../../models/music_artist_identity.dart';
import 'music_listening_timeline.dart';
import 'music_playlist_entry_replacement.dart';
import 'music_playlist_membership_dialog.dart';
import 'music_saved_song_title_dialog.dart';
import 'music_track_details.dart';
import 'music_file_sharing.dart';
import 'music_passage_bookmarks_sheet.dart';
import 'music_song_operation.dart';
import 'music_ringtone.dart';

final _catalogSongId = RegExp(r'^[A-Za-z0-9_-]{11}$');
void _showActionError(BuildContext context) {
  final message = AppLocalizations.of(context)!.musicLibraryActionError;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

bool _matchesCompletedDownload(DownloadedVideo record, String id) =>
    record.videoId == id &&
    record.profileId == db.profileId &&
    record.downloadComplete &&
    !record.downloadFailed &&
    !record.storageFailed &&
    !record.authenticationRequired;

/// A dialog or collection operation may outlive its original profile.
class MusicLibrarySession {
  final AppCubit app;
  final AppState _initial;
  final String _profileId;
  final Service _service;
  final IDbClient _playlistOwner;
  final MusicLibraryService library;
  final RecommendationService _recommendations;
  final int _recommendationGeneration;

  MusicLibrarySession(this.app)
      : _initial = app.state,
        _profileId = db.profileId,
        _service = service,
        _playlistOwner = db.forProfile(db.profileId),
        library = MusicLibraryService.forProfile(db, db.profileId),
        _recommendations = RecommendationService.forProfile(db, db.profileId),
        _recommendationGeneration = RecommendationService.forProfile(
          db,
          db.profileId,
        ).generation(RecommendationDomain.music);

  bool get isCurrent =>
      !app.isClosed &&
      !app.state.globalLoading &&
      !app.state.sessionRecoveryRequired &&
      db.profileId == _profileId &&
      app.state.profileId == _initial.profileId &&
      app.state.sessionRevision == _initial.sessionRevision &&
      app.state.server == _initial.server;

  Future<T?> showDialog<T>(BuildContext context, WidgetBuilder builder) async {
    if (!isCurrent) return null;
    final navigator = Navigator.of(context);
    final route = DialogRoute<T>(context: context, builder: builder);
    final changes = app.stream.listen((_) {
      if (!isCurrent && navigator.mounted && route.isActive) {
        navigator.removeRoute(route);
      }
    });
    try {
      return await navigator.push(route);
    } finally {
      await changes.cancel();
    }
  }

  void _requireCurrent() {
    if (!isCurrent) throw StateError('The active profile changed.');
  }

  List<Playlist> get playlists {
    _requireCurrent();
    return _service.getLocalPlaylists(database: _playlistOwner);
  }

  List<DeletedMusicPlaylist> get recentlyDeletedPlaylists {
    _requireCurrent();
    return _service.getRecentlyDeletedMusicPlaylists(database: _playlistOwner);
  }

  Future<bool> deletePlaylist(String playlistId) {
    _requireCurrent();
    return _service.deleteMusicPlaylist(playlistId, isCurrent: () => isCurrent);
  }

  Future<bool> restorePlaylist(DeletedMusicPlaylist selection) {
    _requireCurrent();
    return _service.restoreMusicPlaylist(selection, isCurrent: () => isCurrent);
  }

  Future<int> saveToPlaylist(
    String playlistId,
    List<Video> videos, {
    bool allowDuplicates = false,
    bool Function()? canSave,
  }) async {
    _requireCurrent();
    final added = await _service.appendLocalPlaylistEntries(
      playlistId,
      videos,
      allowDuplicates: allowDuplicates,
      database: _playlistOwner,
      isCurrent: () => isCurrent && canSave?.call() != false,
    );
    _requireCurrent();
    if (added == 0) return 0;
    library.notifyChanged();
    _learnPlaylistSave(videos);
    return added;
  }

  void _learnPlaylistSave(List<Video> videos) {
    // An explicit single-song save is useful feedback. A whole imported or
    // bulk-saved playlist must not look like listening to every recording.
    if (videos.length == 1 &&
        videos.single.musicMetadata != null &&
        !isLocalMusicPlaybackId(videos.single.videoId)) {
      unawaited(_learnSaved(videos.single));
    }
  }

  Future<({int changed, int skipped})> _applyPlaylistMemberships(
      Video song, Map<String, bool> draft,
      {bool Function()? isDeviceCurrent}) async {
    _requireCurrent();
    var deviceUnavailable = false;
    bool canApply() {
      if (!isCurrent) return false;
      deviceUnavailable = isDeviceCurrent?.call() == false;
      return !deviceUnavailable;
    }

    final result = await _service.updateLocalPlaylistMemberships(song, draft,
        database: db.forProfile(_profileId), isCurrent: canApply);
    if (deviceUnavailable) throw StateError('The device song is unavailable.');
    if (result.changed > 0) library.notifyChanged();
    return result;
  }

  Future<bool> createPlaylist(
    String name,
    List<Video> videos, {
    bool allowDuplicates = false,
    bool Function()? canSave,
  }) async {
    _requireCurrent();
    final id = await _service.createLocalPlaylistWithEntries(
      name,
      allowDuplicates ? videos : _unique(videos),
      database: _playlistOwner,
      isCurrent: () => isCurrent && canSave?.call() != false,
    );
    if (id == null) return false;
    _requireCurrent();
    await library.markLocalPlaylist(id);
    _requireCurrent();
    _learnPlaylistSave(videos);
    return true;
  }

  Future<bool> renamePlaylist(PlaylistReference source, String name) async {
    _requireCurrent();
    final renamed = await _service.renameLocalPlaylist(source, name,
        isCurrent: () => isCurrent);
    if (renamed) library.notifyChanged();
    return renamed;
  }

  Future<void> removeFromPlaylist(String playlistId, Video entry) async {
    _requireCurrent();
    if (!playlistId.startsWith('local:')) {
      throw ArgumentError('Choose a local playlist');
    }
    final removed = await _service.removeLocalPlaylistEntry(playlistId, entry,
        database: db.forProfile(_profileId), isCurrent: () => isCurrent);
    _requireCurrent();
    if (removed) library.notifyChanged();
  }

  Future<void> removeCurrentPlaylistEntry(
      PlaylistReference source, Playlist playlist, Video entry,
      {required bool Function() isCurrentEntry}) async {
    _requireCurrent();
    final removed = await _service.removeUniqueLocalPlaylistEntry(
        source, entry, playlist.title,
        isCurrent: () => isCurrent && isCurrentEntry());
    if (removed) library.notifyChanged();
  }

  Future<void> setBookmark(MusicLibraryEntry entry,
      {required bool saved, bool onlyIfAbsent = false}) async {
    _requireCurrent();
    var didSave = saved;
    if (saved && onlyIfAbsent) {
      didSave = await library.saveIfAbsent(entry);
    } else if (saved) {
      await library.save(entry);
    } else {
      await library.remove(entry.kind, entry.id);
    }
    _requireCurrent();
    if (didSave && entry.kind == MusicLibraryKind.song) {
      unawaited(_learnSaved(entry.toVideo()));
    }
  }

  Future<void> setSongLiked(MusicLibraryEntry song, {required bool liked}) {
    _requireCurrent();
    return library.setSongLiked(song, liked: liked);
  }

  Future<void> _learnSaved(Video video) async {
    if (!isCurrent ||
        !_recommendations.learningEnabled(RecommendationDomain.music) ||
        _recommendations.generation(RecommendationDomain.music) !=
            _recommendationGeneration) {
      return;
    }
    try {
      await _recommendations.feedback(
          video, RecommendationDomain.music, RecommendationFeedback.save);
    } catch (_) {
      // Saving succeeded independently of the optional local learning update.
      // Do not log titles, query terms or recommendation state.
      Logger('MusicLibrarySession')
          .warning('Could not update local music preferences.');
    }
  }

  Future<int> download(DownloadManagerCubit manager, List<Video> videos,
      {DownloadContainer? container,
      MusicOfflinePolicy policy = const MusicOfflinePolicy(),
      bool Function()? canStart}) async {
    _requireCurrent();
    if (isTv) return 0;
    final songs = _unique(videos);
    if ((songs.length > 1 || canStart != null) &&
        songs.any((song) => db.getDownloadByVideoId(song.videoId) == null) &&
        !await manager.prepareMusicDownloads()) {
      return 0;
    }
    if (canStart?.call() == false) return 0;
    var added = 0;
    for (final video in songs) {
      _requireCurrent();
      if (await manager.addDownload(video.videoId,
          audioOnly: true,
          quality: highestAudioDownloadQuality,
          musicPolicy: policy,
          container: container,
          video: video)) {
        added++;
      }
    }
    _requireCurrent();
    return added;
  }

  static List<Video> _unique(List<Video> videos) {
    final byId = <String, Video>{};
    for (final video in videos) {
      byId.putIfAbsent(video.videoId, () => video);
    }
    return byId.values.toList();
  }
}

enum _LibraryAction {
  selectSong,
  preview,
  radio,
  play,
  startMix,
  playNext,
  enqueue,
  request,
  saveBookmark,
  removeBookmark,
  editSavedTitle,
  refreshMetadata,
  like,
  unlike,
  save,
  managePlaylists,
  removeFromPlaylist,
  hideInPlaylist,
  replacePlaylistEntry,
  download,
  timeline,
  trackDetails,
  shareLink,
  shareFile,
  setRingtone,
}

enum _RecommendationAction { why, more, less, block, snooze }

enum _PlayingSongAction {
  saveDevice,
  manageDevicePlaylists,
  rename,
  shareFile,
  passageBookmarks,
  localVideo
}

class _OpenPlayingArtist {
  final String id;
  final String name;

  const _OpenPlayingArtist(this.id, this.name);
}

enum _PlaylistSelectionAction {
  play,
  shuffle,
  next,
  append,
  save,
  download,
  removeDownloads,
  removeFromPlaylist,
  removeFromSource,
}

/// Resolves the current files for a Downloads selection in the supplied order.
typedef MusicSelectionDownloadResolver = List<DownloadedVideo>? Function(
    List<Video> playable);

typedef MusicSelectionRemoval = ({String label, Future<void> Function() run});

class MusicPlaylistSelectionActions extends StatefulWidget {
  final List<Video> videos;
  final Future<void> Function(bool shuffle)? onPlay;
  final bool closeOnPlay;
  final VoidCallback? onCompleted;
  final bool Function() isCurrent;
  final PlaylistReference? recommendationSource;
  final int? selectedCount;
  final MusicSelectionDownloadResolver? resolveDownloads;
  final List<OnDeviceMusicEntry>? Function()? resolveOnDevice;
  final LocalMusicLibrary? deviceLibrary;
  final Future<void> Function()? onRemoveDownloads;
  final bool _wholePlaylist;
  final Future<void> Function()? onRemoveFromPlaylist;
  final MusicSelectionRemoval? removal;

  const MusicPlaylistSelectionActions({
    super.key,
    required this.videos,
    required this.onPlay,
    this.closeOnPlay = true,
    required this.onCompleted,
    required this.isCurrent,
    this.recommendationSource,
    this.selectedCount,
    this.resolveDownloads,
    this.resolveOnDevice,
    this.deviceLibrary,
    this.onRemoveDownloads,
    this.onRemoveFromPlaylist,
    this.removal,
  }) : _wholePlaylist = false;

  const MusicPlaylistSelectionActions.wholePlaylist({
    super.key,
    required this.videos,
    required this.onPlay,
    required this.isCurrent,
    this.recommendationSource,
  })  : _wholePlaylist = true,
        onCompleted = null,
        closeOnPlay = true,
        selectedCount = null,
        resolveDownloads = null,
        resolveOnDevice = null,
        deviceLibrary = null,
        onRemoveDownloads = null,
        onRemoveFromPlaylist = null,
        removal = null;

  @override
  State<MusicPlaylistSelectionActions> createState() =>
      _MusicPlaylistSelectionActionsState();
}

class _MusicPlaylistSelectionActionsState
    extends State<MusicPlaylistSelectionActions> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final wholePlaylist = widget._wholePlaylist;
    return PopupMenuButton<Future<void> Function()>(
      key: ValueKey(wholePlaylist
          ? 'music-whole-playlist-actions'
          : 'music-playlist-selection-actions'),
      tooltip: wholePlaylist
          ? locals.musicLibraryActions
          : locals.musicPlaylistSelectionActions,
      enabled: !_busy &&
          (widget.videos.isNotEmpty ||
              widget.resolveOnDevice?.call()?.isNotEmpty == true ||
              widget.onRemoveDownloads != null ||
              widget.removal != null),
      onSelected: (command) => unawaited(command()),
      itemBuilder: (_) {
        // Each command retains the source rows and owner from the moment this
        // menu opened, even if a library or player update rebuilds the button.
        final source = widget;
        final session = MusicLibrarySession(context.read<AppCubit>());
        bool current() => mounted && session.isCurrent && source.isCurrent();
        final catalog = source.videos
            .where((v) => !isLocalMusicPlaybackId(v.videoId))
            .toList();
        final local = source.deviceLibrary ?? LocalMusicLibrary.instance;
        final grant = local.selectionId;
        bool hasDeviceAccess(Video video) =>
            local.acceptsSessionSelection(grant) &&
            local.playlistTrackById(video.videoId, visibleOnly: true) != null;
        final eligible = source.videos
            .where(
                (v) => !isLocalMusicPlaybackId(v.videoId) || hasDeviceAccess(v))
            .toList();
        final playable = eligible
            .where((v) => !v.filtered && !v.filterHide && v.isUpcoming != true)
            .toList();
        final resolve = source.resolveDownloads;
        List<DownloadedVideo>? completedFiles() {
          if (resolve == null || playable.isEmpty) return null;
          final files = resolve(playable);
          if (files == null || files.length != playable.length) return null;
          for (var i = 0; i < files.length; i++) {
            if (!files[i].audioOnly ||
                !_matchesCompletedDownload(files[i], playable[i].videoId)) {
              return null;
            }
          }
          return files;
        }

        final player = context.read<PlayerCubit?>();
        final deviceRows = source.resolveOnDevice?.call();
        final deviceQueue = player != null &&
            deviceRows != null &&
            deviceRows.isNotEmpty &&
            player.canEnqueueOnDeviceMusic(deviceRows);
        bool canEnqueue(
                List<DownloadedVideo>? files, List<OnDeviceMusicEntry>? rows) =>
            player != null &&
            identical(context.read<PlayerCubit?>(), player) &&
            !player.isClosed &&
            player.state.isAudio &&
            (player.state.currentlyPlaying?.musicMetadata ??
                    player.state.offlineCurrentlyPlaying?.musicMetadata) !=
                null &&
            (deviceQueue
                ? rows != null &&
                    rows.isNotEmpty &&
                    player.canEnqueueOnDeviceMusic(rows)
                : playable.isNotEmpty &&
                    (source.resolveOnDevice == null ||
                        playable.length ==
                            (source.selectedCount ?? source.videos.length)) &&
                    (resolve == null || files != null) &&
                    player.canEnqueueMusicSongs(playable, downloads: files));
        final files = completedFiles();
        final fileFingerprints = files?.map(musicDownloadFingerprint).toList();
        final canPlay = widget.onPlay != null &&
            playable.isNotEmpty &&
            (resolve == null || files != null);
        final generation =
            canEnqueue(files, deviceRows) ? player!.playlistGeneration : null;
        List<Video> downloads() {
          if (isTv) return [];
          final playing = player?.state.currentlyPlaying;
          final manager = context.read<DownloadManagerCubit?>();
          return MusicLibrarySession._unique(catalog)
              .where((song) =>
                  !song.downloadPlaybackOnly &&
                  !(playing?.videoId == song.videoId &&
                      playing?.downloadPlaybackOnly == true) &&
                  DownloadedVideo.isSafeFileId(song.videoId) &&
                  (db.getDownloadByVideoId(song.videoId) == null ||
                      manager?.isMusicDownloadPlaylistOnly(song.videoId) ==
                          true))
              .toList();
        }

        Future<void> run(_PlaylistSelectionAction action) async {
          if (_busy || !current()) return;
          setState(() => _busy = true);
          try {
            switch (action) {
              case _PlaylistSelectionAction.play:
              case _PlaylistSelectionAction.shuffle:
                if (resolve != null && completedFiles() == null) return;
                await source.onPlay
                    ?.call(action == _PlaylistSelectionAction.shuffle);
                if (!source.closeOnPlay) return;
              case _PlaylistSelectionAction.next:
              case _PlaylistSelectionAction.append:
                final currentFiles = completedFiles();
                final currentDeviceRows = source.resolveOnDevice?.call();
                if (generation == null ||
                    !canEnqueue(currentFiles, currentDeviceRows) ||
                    player!.playlistGeneration != generation ||
                    (player.state.videos.isNotEmpty &&
                        !listEquals(
                            fileFingerprints,
                            currentFiles
                                ?.map(musicDownloadFingerprint)
                                .toList())) ||
                    !listEquals(deviceRows?.map((row) => row.id).toList(),
                        currentDeviceRows?.map((row) => row.id).toList())) {
                  throw StateError('The active music queue changed.');
                }
                final next = action == _PlaylistSelectionAction.next;
                final queued = deviceQueue
                    ? await player.enqueueOnDeviceMusic(currentDeviceRows!,
                        next: next, isCurrent: current)
                    : await player.enqueueMusicSongs(playable,
                        next: next,
                        downloads: currentFiles,
                        recommendationSource: source.recommendationSource);
                if (!queued) {
                  throw StateError('The active music queue changed.');
                }
              case _PlaylistSelectionAction.save:
                if (!await MusicLibraryActions._showSave(
                    context, resolve == null ? eligible : playable,
                    canSave: () =>
                        current() &&
                        eligible
                            .where((video) =>
                                isLocalMusicPlaybackId(video.videoId))
                            .every(hasDeviceAccess) &&
                        (resolve == null || completedFiles() != null))) {
                  return;
                }
              case _PlaylistSelectionAction.download:
                final count = await MusicLibraryActions.download(
                    context, downloads(),
                    canDownload: current);
                if (count == 0) return;
              case _PlaylistSelectionAction.removeDownloads:
                await source.onRemoveDownloads?.call();
                return;
              case _PlaylistSelectionAction.removeFromPlaylist:
                await source.onRemoveFromPlaylist?.call();
                return;
              case _PlaylistSelectionAction.removeFromSource:
                await source.removal?.run();
                return;
            }
            if (current()) source.onCompleted?.call();
          } catch (_) {
            if (!context.mounted || !current()) return;
            final message = switch (action) {
              _PlaylistSelectionAction.save ||
              _PlaylistSelectionAction.download ||
              _PlaylistSelectionAction.removeFromSource ||
              _PlaylistSelectionAction.removeFromPlaylist =>
                locals.musicLibraryActionError,
              _PlaylistSelectionAction.removeDownloads =>
                locals.musicDownloadError,
              _ => locals.musicPlaybackError,
            };
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(message)));
          } finally {
            if (mounted) setState(() => _busy = false);
          }
        }

        PopupMenuItem<Future<void> Function()> item(
                _PlaylistSelectionAction action, String label, bool enabled) =>
            PopupMenuItem(
                value: () => run(action), enabled: enabled, child: Text(label));
        return [
          if (resolve != null &&
              (source.selectedCount ?? 0) > source.videos.length)
            PopupMenuItem<Future<void> Function()>(
                enabled: false,
                child: Text(locals
                    .musicSelectedCompletedDownloads(source.videos.length))),
          if (resolve == null || files != null) ...[
            if (!wholePlaylist && source.onPlay != null)
              item(_PlaylistSelectionAction.play, locals.musicPlay, canPlay),
            if (source.onPlay != null)
              item(_PlaylistSelectionAction.shuffle, locals.musicShuffle,
                  canPlay),
            item(_PlaylistSelectionAction.next, locals.playNext,
                generation != null),
            item(_PlaylistSelectionAction.append, locals.addToQueueList,
                generation != null),
            if (!wholePlaylist)
              item(_PlaylistSelectionAction.save, locals.musicSaveToPlaylist,
                  eligible.isNotEmpty),
          ],
          if (!wholePlaylist && resolve == null && downloads().isNotEmpty)
            item(_PlaylistSelectionAction.download, locals.musicDownloadAudio,
                true),
          if (source.onRemoveDownloads != null)
            item(_PlaylistSelectionAction.removeDownloads,
                locals.musicRemoveSelectedDownloads, true),
          if (source.onRemoveFromPlaylist != null)
            item(_PlaylistSelectionAction.removeFromPlaylist,
                locals.musicPlaylistRemoveSelected, source.videos.isNotEmpty),
          if (source.removal case final removal?)
            item(_PlaylistSelectionAction.removeFromSource, removal.label,
                (source.selectedCount ?? source.videos.length) > 0),
        ];
      },
    );
  }
}

/// Actions available for a song shown in Music recommendations.
class MusicSongRecommendation {
  final String? reason;
  final ValueChanged<RecommendationFeedback>? onFeedback;
  final Future<void> Function()? onSnooze;
  final bool Function() isCurrent;

  const MusicSongRecommendation(
      {this.reason, this.onFeedback, this.onSnooze, required this.isCurrent});

  DialogRoute<void> _explanation(BuildContext context, String reason) =>
      DialogRoute<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(AppLocalizations.of(context)!.recommendationWhy),
          content: Text(reason),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child:
                    Text(MaterialLocalizations.of(context).closeButtonLabel)),
          ],
        ),
      );
}

class _RecommendedSongMenu extends StatelessWidget {
  final List<PopupMenuEntry<_LibraryAction>> songItems;
  final MusicSongRecommendation recommendation;

  const _RecommendedSongMenu(this.songItems, this.recommendation);

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    Widget section(String title, List<Widget> items) => FocusTraversalGroup(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 12, 4),
                child: Semantics(
                    header: true,
                    child: Text(title,
                        style: Theme.of(context).textTheme.titleSmall))),
            ...items,
          ]),
        );
    final song = section(locals.musicLibraryActions, songItems);
    final feedback = section(locals.localRecommendations, [
      if (recommendation.reason != null)
        PopupMenuItem(
            value: _RecommendationAction.why,
            child: Text(locals.recommendationWhy)),
      if (recommendation.onFeedback != null)
        for (final (action, label) in [
          (_RecommendationAction.more, locals.recommendationMoreLikeThis),
          (_RecommendationAction.less, locals.recommendationNotInterested),
          (_RecommendationAction.block, locals.recommendationBlockCreator),
        ])
          PopupMenuItem(value: action, child: Text(label)),
      if (recommendation.onSnooze != null)
        PopupMenuItem(
            value: _RecommendationAction.snooze,
            child: Text(locals.musicSnoozeDiscovery)),
    ]);
    return Dialog(
      constraints: const BoxConstraints(maxWidth: 640),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(builder: (context, bounds) {
          final minColumnWidth =
              MediaQuery.textScalerOf(context).scale(16) * 16;
          return Semantics(
            role: SemanticsRole.menu,
            explicitChildNodes: true,
            label: locals.musicLibraryActions,
            child: SingleChildScrollView(
              child: bounds.maxWidth >= minColumnWidth * 2 + 16
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                          Expanded(child: song),
                          const SizedBox(width: 16),
                          Expanded(child: feedback),
                        ])
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                          song,
                          const Divider(),
                          feedback,
                        ]),
            ),
          );
        }),
      ),
    );
  }
}

class MusicLibraryActions extends StatefulWidget {
  final List<Video> videos;
  final bool compact;
  final String? localPlaylistId;
  final PlaylistReference? playlistVisibility;
  final PlaylistReference? replacementPlaylist;
  final ButtonStyle? iconStyle;
  final bool inPlayer;
  final Future<void> Function()? onPlay;
  final PlaylistReference? recommendationSource;
  final List<DownloadedVideo>? downloads;
  final MusicSongRecommendation? recommendation;
  final VoidCallback? onSelectSong;

  const MusicLibraryActions(
      {super.key,
      required this.videos,
      this.compact = true,
      this.localPlaylistId,
      this.playlistVisibility,
      this.replacementPlaylist,
      this.iconStyle,
      this.inPlayer = false,
      this.onPlay,
      this.recommendationSource,
      this.downloads,
      this.recommendation,
      this.onSelectSong});

  static MusicLibraryEntry? _song(List<Video> videos) => videos.length == 1 &&
          videos.single.musicMetadata != null &&
          !isLocalMusicPlaybackId(videos.single.videoId)
      ? MusicLibraryEntry.song(videos.single)
      : null;

  static Future<void> _refreshSongMetadata(
      BuildContext context,
      MusicLibrarySession session,
      String id,
      bool Function()? isCurrent) async {
    final database = db;
    final catalog = musicCatalogService;
    final proxy = NetworkProxy.instance;
    final config = proxy.config;
    var connectionChanged = false;
    bool current() =>
        context.mounted &&
        session.isCurrent &&
        isCurrent?.call() != false &&
        identical(db, database) &&
        identical(service, session._service) &&
        identical(musicCatalogService, catalog) &&
        !connectionChanged &&
        !proxy.isChanging &&
        identical(proxy.config, config);
    Future<void> onProxyChange() async {
      connectionChanged = true;
    }

    proxy.addBeforeApply(onProxyChange);
    try {
      final refreshed = await session.library.refreshSongMetadata(id,
          isCurrent: current, load: (requestIsCurrent) async {
        MusicLibraryEntry? details;
        await catalog.loadSavedSongDetails([id], isCurrent: requestIsCurrent,
            onResult: (resultId, result) async {
          if (resultId == id) details = result;
        });
        return details;
      });
      if (!refreshed || !context.mounted || !current()) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context)!.musicMetadataRefreshed)));
    } catch (_) {
      if (!context.mounted || !current()) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(AppLocalizations.of(context)!.musicMetadataRefreshFailed)));
    } finally {
      proxy.removeBeforeApply(onProxyChange);
    }
  }

  static bool _canQueueSongs(PlayerCubit? player, List<Video> videos,
          List<DownloadedVideo>? downloads) =>
      player != null &&
      !player.isClosed &&
      (!player.state.hasVideo ||
          player.state.isHidden ||
          player.state.isClosing ||
          player.canEnqueueMusicSongs(videos, downloads: downloads));

  static IdedVideo? _requestEntry(
      List<Video> videos, List<DownloadedVideo>? downloads) {
    if (videos.length != 1) return null;
    if (downloads == null) return videos.single;
    if (downloads.length != 1 ||
        !_matchesCompletedDownload(downloads.single, videos.single.videoId)) {
      return null;
    }
    return downloads.single;
  }

  static void addRequest(
      BuildContext context, PlayerCubit player, IdedVideo entry,
      {PlaylistReference? recommendationSource,
      bool inheritCurrentRecommendationSource = false}) {
    if (!player.addMusicRequest(entry,
        recommendationSource: recommendationSource,
        inheritCurrentRecommendationSource:
            inheritCurrentRecommendationSource)) {
      throw StateError('The song can no longer be requested.');
    }
    final locals = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(locals.musicRequestAdded)));
  }

  static DownloadedVideo? _shareableDownload(
      Video song, List<DownloadedVideo>? downloads) {
    final pinned = song.explicitMusicDownload;
    final file =
        downloads == null && (pinned != null || song.downloadPlaybackOnly)
            ? readyMusicDownload(db, song.videoId, fingerprint: pinned)
            : downloads?.singleOrNull;
    return file != null &&
            file.videoId == song.videoId &&
            canShareDownloadedMusicFile(file)
        ? file
        : null;
  }

  static PopupMenuItem<_LibraryAction> _likeItem(
      AppLocalizations locals, bool liked) {
    return PopupMenuItem(
        key: const ValueKey('music-song-like'),
        value: liked ? _LibraryAction.unlike : _LibraryAction.like,
        child: Text(liked ? locals.musicUnlikeSong : locals.musicLikeSong));
  }

  static bool _canManageSongPlaylists(List<Video> videos) =>
      videos.length == 1 &&
      (_song(videos) != null ||
          LocalMusicLibrary.instance.playlistTrackById(videos.single.videoId,
                  visibleOnly: true) !=
              null);

  static MusicRingtoneSource? _ringtoneForSong(
      Video? song, List<DownloadedVideo>? downloads,
      {required bool Function() isCurrent,
      DownloadedVideo? Function()? resolveDownload}) {
    if (song == null || isTv || !supportsMusicFileSharing) return null;
    if (isLocalMusicPlaybackId(song.videoId)) {
      final track = localMusicTrackForPlayback(song.videoId);
      if (track == null) return null;
      final library = LocalMusicLibrary.instance;
      final selection = library.selectionId;
      return MusicRingtoneSource.local(library, track,
          isCurrent: () =>
              isCurrent() && library.acceptsSessionSelection(selection));
    }
    final pinned = song.explicitMusicDownload;
    final file =
        downloads == null && (pinned != null || song.downloadPlaybackOnly)
            ? readyMusicDownload(db, song.videoId, fingerprint: pinned)
            : downloads?.singleOrNull;
    if (file == null || file.videoId != song.videoId) return null;
    final fingerprint = musicDownloadFingerprint(file);
    return MusicRingtoneSource.download(file, isCurrent: () {
      if (!isCurrent()) return false;
      if (resolveDownload == null) return true;
      final latest = resolveDownload();
      return latest != null && musicDownloadFingerprint(latest) == fingerprint;
    });
  }

  static List<PopupMenuEntry<_LibraryAction>> _items(
      BuildContext context, List<Video> videos, String? playlistId,
      {required Widget Function(Widget) first,
      List<DownloadedVideo>? downloads,
      bool canReplacePlaylistEntry = false,
      bool nowPlaying = false,
      bool canHideInPlaylist = false,
      bool canSelectSong = false,
      bool showDownload = true}) {
    final locals = AppLocalizations.of(context)!;
    final song = _song(videos);
    final library = MusicLibraryService.forProfile(db, db.profileId);
    final saved = song != null && library.contains(song.kind, song.id);
    final player = context.read<PlayerCubit?>();
    final playableDevice = videos.length == 1 &&
        LocalMusicLibrary.instance.playlistTrackById(videos.single.videoId) !=
            null;
    final canSave = videos.any((video) =>
        !isLocalMusicPlaybackId(video.videoId) ||
        LocalMusicLibrary.instance
                .playlistTrackById(video.videoId, visibleOnly: true) !=
            null);
    final canQueue = _canQueueSongs(player, videos, downloads);
    final request = _requestEntry(videos, downloads);
    final addLabel =
        nowPlaying ? locals.addToPlaylist : locals.musicSaveToPlaylist;
    return [
      if (song != null) ...[
        PopupMenuItem(
            key: const ValueKey('music-song-play'),
            value: _LibraryAction.play,
            child: first(Text(locals.musicPlay))),
        if (canSelectSong)
          PopupMenuItem(
              value: _LibraryAction.selectSong,
              child: Text(locals.musicSelectSong)),
        if (downloads == null &&
            context.read<AppCubit>().state.server != null &&
            !videos.single.filtered &&
            !videos.single.filterHide &&
            !videos.single.downloadPlaybackOnly &&
            videos.single.explicitMusicDownload == null &&
            !isLocalMusicPlaybackId(videos.single.videoId))
          PopupMenuItem(
              key: const ValueKey('music-song-start-mix'),
              value: _LibraryAction.startMix,
              child: Text(locals.musicStartMix)),
        PopupMenuItem(
            key: const ValueKey('music-song-play-next'),
            value: _LibraryAction.playNext,
            enabled: canQueue,
            child: Text(locals.playNext)),
        PopupMenuItem(
            key: const ValueKey('music-song-add-to-queue'),
            value: _LibraryAction.enqueue,
            enabled: canQueue,
            child: Text(locals.addToQueueList)),
        if (request != null && player?.canAddMusicRequest(request) == true)
          PopupMenuItem(
              key: const ValueKey('music-song-add-to-requests'),
              value: _LibraryAction.request,
              child: Text(locals.musicAddToRequests)),
        if (player != null &&
            downloads == null &&
            canUseOnlineMusicSong(videos.single)) ...[
          PopupMenuItem(
              value: _LibraryAction.preview,
              child: Text(locals.musicPreviewSong)),
          PopupMenuItem(
              value: _LibraryAction.radio, child: Text(locals.musicRadioStart)),
        ],
        const PopupMenuDivider(),
        PopupMenuItem(
            value: saved
                ? _LibraryAction.removeBookmark
                : _LibraryAction.saveBookmark,
            child: Text(saved ? locals.musicRemoveSong : locals.musicSaveSong)),
        _likeItem(locals, library.isLiked(song.id)),
        if (saved)
          PopupMenuItem(
              key: const ValueKey('music-edit-saved-song-title'),
              value: _LibraryAction.editSavedTitle,
              child: Text(locals.musicEditSavedSongTitle)),
        PopupMenuItem(
          value: _LibraryAction.trackDetails,
          child: Text(
            downloads != null ||
                    videos.single.explicitMusicDownload != null ||
                    videos.single.downloadPlaybackOnly
                ? locals.musicTrackFileDetails
                : locals.musicTrackDetails,
          ),
        ),
        if (downloads == null &&
            !videos.single.downloadPlaybackOnly &&
            library.canRefreshSongMetadata(song.id))
          PopupMenuItem(
              key: const ValueKey('music-song-refresh-metadata'),
              value: _LibraryAction.refreshMetadata,
              child: Text(locals.musicRefreshSongMetadata)),
      ],
      if (playableDevice)
        PopupMenuItem(
            key: const ValueKey('music-song-play'),
            value: _LibraryAction.play,
            child: first(Text(locals.musicPlay))),
      if (canSave)
        PopupMenuItem(
            value: _LibraryAction.save,
            child: song == null && !playableDevice
                ? first(Text(addLabel))
                : Text(addLabel)),
      if (_canManageSongPlaylists(videos))
        PopupMenuItem(
            value: _LibraryAction.managePlaylists,
            child: Text(locals.musicManageSongPlaylists)),
      if (playlistId?.startsWith('local:') == true && videos.length == 1)
        PopupMenuItem(
            value: _LibraryAction.removeFromPlaylist,
            child: Text(locals.removeFromPlayList)),
      if (canReplacePlaylistEntry)
        PopupMenuItem(
            value: _LibraryAction.replacePlaylistEntry,
            child: Text(locals.musicReplacePlaylistEntry)),
      if (song != null && _catalogSongId.stringMatch(song.id) == song.id)
        PopupMenuItem(
            value: _LibraryAction.shareLink,
            child: Text(locals.musicShareSongLink)),
      if (song != null && _shareableDownload(videos.single, downloads) != null)
        PopupMenuItem(
            value: _LibraryAction.shareFile,
            child: Text(locals.musicShareAudioFile)),
      if (canHideInPlaylist && song != null)
        PopupMenuItem(
            value: _LibraryAction.hideInPlaylist,
            child: Text(locals.musicHideSongInPlaylist)),
      if (!isTv &&
          showDownload &&
          videos.any((v) => !isLocalMusicPlaybackId(v.videoId)))
        PopupMenuItem(
            value: _LibraryAction.download,
            child: Text(locals.musicDownloadAudio)),
      if (song != null)
        PopupMenuItem(
            key: const ValueKey('music-song-listening-timeline'),
            value: _LibraryAction.timeline,
            child: Text(locals.musicListeningTimeline)),
    ];
  }

  static Future<void> queueSong(
      BuildContext context, Video song, MusicSongRowSwipeAction action,
      {DownloadedVideo? download,
      PlaylistReference? recommendationSource}) async {
    final queueAction = switch (action) {
      MusicSongRowSwipeAction.off => null,
      MusicSongRowSwipeAction.playNext => _LibraryAction.playNext,
      MusicSongRowSwipeAction.addToQueue => _LibraryAction.enqueue,
    };
    if (queueAction == null ||
        !context.mounted ||
        song.musicMetadata == null ||
        (download != null &&
            !_matchesCompletedDownload(download, song.videoId))) {
      return;
    }
    final app = context.read<AppCubit>();
    final session = MusicLibrarySession(app);
    if (app.state.profileId != db.profileId || !session.isCurrent) return;
    final videos = [song];
    final downloads = download == null ? null : [download];
    try {
      if (!_canQueueSongs(context.read<PlayerCubit?>(), videos, downloads)) {
        _showActionError(context);
        return;
      }
      await _apply(context, session, queueAction, videos, null, null, downloads,
          inPlayer: false, recommendationSource: recommendationSource);
    } catch (_) {
      if (context.mounted && session.isCurrent) _showActionError(context);
    }
  }

  static Future<void> _apply(
      BuildContext context,
      MusicLibrarySession session,
      _LibraryAction action,
      List<Video> videos,
      String? playlistId,
      Future<void> Function()? onPlay,
      List<DownloadedVideo>? downloads,
      {required bool inPlayer,
      PlaylistReference? recommendationSource,
      bool Function()? isCurrent}) async {
    if (!context.mounted || !session.isCurrent || isCurrent?.call() == false) {
      return;
    }
    if (action == _LibraryAction.preview || action == _LibraryAction.radio) {
      final player = context.read<PlayerCubit?>();
      final song = videos.singleOrNull;
      if (player == null ||
          song == null ||
          downloads != null ||
          !canUseOnlineMusicSong(song)) {
        return;
      }
      bool current() =>
          context.mounted &&
          session.isCurrent &&
          !player.isClosed &&
          isCurrent?.call() != false;
      if (!current()) return;
      final locals = AppLocalizations.of(context)!;
      final navigator = Navigator.of(context);
      final source = ModalRoute.of(context);
      final occurrence = player.playbackOccurrenceRevision;
      final selection = player.musicSelectionRequestRevision;
      final transport = player.transportIntentRevision;
      final preview = action == _LibraryAction.preview;
      final playlist = player.playlistGeneration;
      final queue = player.musicQueueRevision;
      bool operationCurrent() =>
          current() &&
          (preview ||
              (playlist == player.playlistGeneration &&
                  queue == player.musicQueueRevision));
      final radioTitle =
          preview ? null : locals.musicRadioTitle(song.musicMetadata!.title);
      final keepMounted = !preview && player.isCurrentMusicSongRadioSeed(song);
      ({Video song, bool Function() isCurrent})? fullSong;
      final songs = await showDialog<List<Video>>(
          context: context,
          useRootNavigator: false,
          builder: (_) => MusicSongOperation(
              song: song,
              player: player,
              preview: preview,
              isSessionCurrent: () => session.isCurrent,
              isCurrent: operationCurrent,
              sessionChanges: session.app.stream,
              startCurrentRadio: keepMounted
                  ? (isCurrent) => player.startCurrentMusicSongRadio(song,
                      queueTitle: radioTitle!, isCurrent: isCurrent)
                  : null,
              previewSaveAction: (song, isCurrent) => _PreviewSaveAction(
                  key: ObjectKey(song),
                  session: session,
                  entry: MusicLibraryEntry.song(song),
                  isCurrent: isCurrent),
              onPlayFullSong: preview
                  ? (selected, isCurrent) {
                      fullSong = (song: selected, isCurrent: isCurrent);
                    }
                  : null));
      if (fullSong case final request?) {
        if (!navigator.mounted ||
            source?.isCurrent == false ||
            !session.isCurrent ||
            player.isClosed ||
            !request.isCurrent()) {
          return;
        }
        final selected = request.song;
        // The original row callback retains its collection and occurrence.
        if (identical(selected, song) && onPlay != null && current()) {
          await onPlay();
        } else if (inPlayer &&
            identical(selected, song) &&
            player.state.currentQueueId == playbackQueueId(selected)) {
          player.seek(Duration.zero);
          player.play();
        } else if (isTv ? inPlayer : !context.mounted) {
          await player.playVideo([selected],
              startAt: Duration.zero, audio: true, fromMusic: true);
        } else {
          await MusicScreen.playTracks(
              context.mounted ? context : navigator.context, [selected]);
        }
        return;
      }
      if (!context.mounted ||
          songs == null ||
          !operationCurrent() ||
          source?.isCurrent == false ||
          player.playbackOccurrenceRevision != occurrence ||
          player.musicSelectionRequestRevision != selection ||
          player.transportIntentRevision != transport) {
        return;
      }
      if (inPlayer && isTv) {
        await player.playVideo(songs,
            queueTitle: radioTitle, audio: true, fromMusic: true);
      } else {
        await MusicScreen.playTracks(context, songs, queueTitle: radioTitle);
      }
    } else if (action == _LibraryAction.startMix) {
      await MusicScreen.playSeededMix(context, videos.single,
          inPlayer: inPlayer,
          isCurrent: () =>
              context.mounted &&
              session.isCurrent &&
              isCurrent?.call() != false);
    } else if (action == _LibraryAction.request) {
      if (isCurrent?.call() == false) return;
      final request = _requestEntry(videos, downloads);
      if (request != null) {
        addRequest(context, context.read<PlayerCubit>(), request,
            recommendationSource: recommendationSource);
      }
    } else if (action == _LibraryAction.play ||
        action == _LibraryAction.playNext ||
        action == _LibraryAction.enqueue) {
      final player = context.read<PlayerCubit>();
      if (player.isClosed) return;
      if (action != _LibraryAction.play &&
          player.state.hasVideo &&
          !player.state.isHidden &&
          !player.state.isClosing &&
          player.state.currentQueueId != null) {
        // Muzza SongMenu / QueueSelectionMenu enqueue fresh occurrences,
        // preserving the active song and the user's existing upcoming order.
        if (!await player.enqueueMusicSongs(videos,
            next: action == _LibraryAction.playNext,
            downloads: downloads,
            recommendationSource: recommendationSource)) {
          throw StateError('The active queue changed.');
        }
      } else if (action == _LibraryAction.play && onPlay != null) {
        await onPlay();
      } else if (downloads != null) {
        await player.playOfflineVideos(downloads, fromMusic: true);
      } else {
        await MusicScreen.playTracks(context, videos,
            recommendationSource: recommendationSource);
      }
    } else if (action == _LibraryAction.trackDetails) {
      final song = videos.single;
      final selectedDownload = downloads?.singleOrNull;
      final fingerprint =
          song.explicitMusicDownload ?? selectedDownload?.explicitMusicDownload;
      final file = selectedDownload ??
          (fingerprint != null || song.downloadPlaybackOnly
              ? readyMusicDownload(db, song.videoId, fingerprint: fingerprint)
              : null);
      if (file != null) {
        await showMusicTrackDetails(context,
            download: file,
            downloadFileProof: fingerprint == null
                ? null
                : pinnedMusicDownloadFileProof(fingerprint),
            inPlayer: inPlayer);
      } else if (downloads == null &&
          fingerprint == null &&
          !song.downloadPlaybackOnly) {
        await showMusicTrackDetails(context, song: song, inPlayer: inPlayer);
      }
    } else if (action == _LibraryAction.saveBookmark ||
        action == _LibraryAction.removeBookmark) {
      final song = _song(videos);
      if (song != null) {
        await session.setBookmark(song,
            saved: action == _LibraryAction.saveBookmark);
      }
    } else if (action == _LibraryAction.like ||
        action == _LibraryAction.unlike) {
      final song = _song(videos);
      if (song != null) {
        await session.setSongLiked(song, liked: action == _LibraryAction.like);
      }
    } else if (action == _LibraryAction.editSavedTitle) {
      final entry = session.library.savedSong(videos.single.videoId);
      bool current() =>
          context.mounted && session.isCurrent && (isCurrent?.call() ?? true);
      if (entry != null && current()) {
        await showSavedSongTitleEditor(context,
            entry: entry,
            isCurrent: current,
            inPlayer: inPlayer,
            onSave: (title) => session.library
                .setSavedSongTitle(entry.id, title, isCurrent: current));
      }
    } else if (action == _LibraryAction.refreshMetadata) {
      if (videos.length == 1 &&
          downloads == null &&
          !videos.single.downloadPlaybackOnly) {
        await _refreshSongMetadata(
            context, session, videos.single.videoId, isCurrent);
      }
    } else if (action == _LibraryAction.save) {
      final library = LocalMusicLibrary.instance;
      final selection = library.selectionId;
      bool currentDevice(Video video) =>
          library.acceptsSessionSelection(selection) &&
          library.playlistTrackById(video.videoId, visibleOnly: true) != null;
      final eligible = videos
          .where((video) =>
              !isLocalMusicPlaybackId(video.videoId) || currentDevice(video))
          .toList();
      if (eligible.isEmpty) return;
      await _showSave(context, eligible,
          inPlayer: inPlayer,
          canSave: () =>
              isCurrent?.call() != false &&
              eligible
                  .where((v) => isLocalMusicPlaybackId(v.videoId))
                  .every(currentDevice));
    } else if (action == _LibraryAction.managePlaylists) {
      await _manageSongPlaylists(context, session, videos.single,
          inPlayer: inPlayer, isCurrentSong: isCurrent);
    } else if (action == _LibraryAction.removeFromPlaylist) {
      if (playlistId != null && videos.length == 1) {
        await session.removeFromPlaylist(playlistId, videos.single);
      }
    } else if (action == _LibraryAction.timeline) {
      final song = _song(videos);
      if (song != null) {
        await showMusicListeningTimeline(context,
            trackId: song.id, title: song.title, inPlayer: inPlayer);
      }
    } else if (action == _LibraryAction.shareLink) {
      final song = videos.single;
      if (_catalogSongId.stringMatch(song.videoId) == song.videoId) {
        showSharingSheet(context, song, inPlayer: inPlayer);
      }
    } else if (action == _LibraryAction.shareFile) {
      final song = videos.single;
      final file = _shareableDownload(song, downloads);
      if (file != null) {
        final fingerprint =
            song.explicitMusicDownload ?? file.explicitMusicDownload;
        await shareDownloadedMusicFile(context, file,
            expectedIdentity: fingerprint == null
                ? null
                : pinnedMusicDownloadFileProof(fingerprint),
            isCurrent: () =>
                context.mounted &&
                session.isCurrent &&
                (isCurrent?.call() ?? true));
      }
    } else {
      await download(context, videos,
          inPlayer: inPlayer, canDownload: isCurrent);
    }
  }

  static Future<void> showPlayingSongMenu(BuildContext context, IdedVideo entry,
      {required bool television}) async {
    final app = context.read<AppCubit>();
    final player = context.read<PlayerCubit>();
    final session = MusicLibrarySession(app);
    final source = player.playlistReference;
    final recommendationSource =
        player.musicRecommendationSourceForCurrentEntry;
    final playlistGeneration = player.playlistGeneration;
    final occurrenceRevision = player.playbackOccurrenceRevision;
    final selectionRevision = player.musicSelectionRequestRevision;
    final occurrence = playbackQueueId(entry);
    bool current() =>
        context.mounted &&
        session.isCurrent &&
        identical(context.read<AppCubit>(), app) &&
        identical(context.read<PlayerCubit>(), player) &&
        !player.isClosed &&
        player.state.isAudio &&
        !player.state.isHidden &&
        !player.state.isClosing &&
        !player.state.isMini &&
        player.openingMusicEntry == null &&
        player.playlistReference == source &&
        player.playlistGeneration == playlistGeneration &&
        player.playbackOccurrenceRevision == occurrenceRevision &&
        player.musicSelectionRequestRevision == selectionRevision &&
        player.state.currentQueueId == occurrence &&
        (player.state.currentlyPlaying ?? player.state.offlineCurrentlyPlaying)
                ?.videoId ==
            entry.videoId;
    if (!current()) return;

    final locals = AppLocalizations.of(context)!;
    final video = entry is Video ? entry : null;
    final file = entry is DownloadedVideo ? entry : null;
    final music = video?.musicMetadata ?? file?.musicMetadata;
    if (music == null) return;
    final onDevice = isLocalMusicPlaybackId(entry.videoId);
    final song = catalogMusicVideoForPlayback(entry);
    final downloads = file != null && !onDevice ? [file] : null;
    final track = onDevice ? localMusicTrackForPlayback(entry.videoId) : null;
    final localLibrary = LocalMusicLibrary.instance;
    final localSelection = onDevice ? localLibrary.selectionId : null;
    final playlistEntry = player.currentLocalPlaylistEntry;
    final playlist = source == null || playlistEntry == null
        ? null
        : session._service
            .getLocalPlaylistWithUniqueEntry(source, playlistEntry);
    final title = playlist?.playlistId == localWatchLaterId
        ? locals.watchLater
        : normalizedQueueTitle(playlist?.title);
    final artists = <String, String>{
      if (!onDevice)
        for (final credit in music.artistCredits)
          if (normalizeChannelId(credit.id) case final id?) id: credit.name,
    };
    ModalRoute<dynamic>? route;
    Widget first(Widget child) => Builder(builder: (context) {
          route = ModalRoute.of(context);
          return PlayerModalBackHandler(child: child);
        });
    void dismissStaleMenu() {
      if (!current() && route?.isActive == true) {
        route!.navigator?.removeRoute(route!);
      }
    }

    final canCopy = file != null && player.canCopyOfflineMusicEntries([file]);
    final ringtone = television
        ? null
        : track != null
            ? MusicRingtoneSource.local(localLibrary, track,
                isCurrent: () =>
                    current() &&
                    localLibrary.acceptsSessionSelection(localSelection))
            : _ringtoneForSong(song, downloads, isCurrent: current);
    final entries = <PopupMenuEntry<Object>>[
      if (song != null)
        ..._items(context, [song], null,
            first: first,
            downloads: downloads,
            nowPlaying: true,
            showDownload: !television &&
                video != null &&
                !video.downloadPlaybackOnly &&
                video.explicitMusicDownload == null)
      else ...[
        PopupMenuItem(
            value: _LibraryAction.play, child: first(Text(locals.musicPlay))),
        if (canCopy) ...[
          PopupMenuItem(
              value: _LibraryAction.playNext, child: Text(locals.playNext)),
          PopupMenuItem(
              value: _LibraryAction.enqueue,
              child: Text(locals.addToQueueList)),
        ],
        if (track != null && devicePlaylistVideo(track) != null) ...[
          PopupMenuItem(
              value: _PlayingSongAction.saveDevice,
              child: Text(locals.addToPlaylist)),
          PopupMenuItem(
              value: _PlayingSongAction.manageDevicePlaylists,
              child: Text(locals.musicManageSongPlaylists)),
        ],
        if (player.canAddMusicRequest(entry))
          PopupMenuItem(
              key: const ValueKey('music-song-add-to-requests'),
              value: _LibraryAction.request,
              child: Text(locals.musicAddToRequests)),
        if (track != null)
          _likeItem(locals, session.library.isLiked(track.playbackId)),
        if (track?.canRename == true &&
            track?.fileName != null &&
            !localLibrary.busy)
          PopupMenuItem(
              value: _PlayingSongAction.rename,
              child: Text(locals.localMusicRename)),
        PopupMenuItem(
            key: const ValueKey('music-song-listening-timeline'),
            value: _LibraryAction.timeline,
            child: Text(locals.musicListeningTimeline)),
        if (track != null)
          PopupMenuItem(
              value: _LibraryAction.trackDetails,
              child: Text(locals.musicTrackFileDetails)),
        if (track != null && !track.isCueTrack && supportsMusicFileSharing)
          PopupMenuItem(
              value: _PlayingSongAction.shareFile,
              enabled: !localLibrary.busy,
              child: Text(locals.musicShareAudioFile)),
        if (track != null && LocalMusicVideoPairings.supported)
          PopupMenuItem(
              key: const ValueKey('music-player-local-video-menu'),
              value: _PlayingSongAction.localVideo,
              child: Text(locals.localMusicPairedVideo)),
      ],
      if (player.captureMusicPassage() != null)
        PopupMenuItem(
          key: const ValueKey('music-player-passage-bookmarks'),
          value: _PlayingSongAction.passageBookmarks,
          child: Text(locals.musicPassageBookmarks),
        ),
      if (ringtone != null)
        MusicRingtoneMenuItem<Object>(
            source: ringtone, value: _LibraryAction.setRingtone),
      if (title != null && playlist?.isEditLocked == false)
        PopupMenuItem(
            key: const ValueKey('music-player-remove-from-playlist'),
            value: _LibraryAction.removeFromPlaylist,
            child: Text(locals.musicRemoveFromNamedPlaylist(title))),
      for (final artist in artists.entries)
        PopupMenuItem(
            key: ValueKey(('music-player-open-artist', artist.key)),
            value: _OpenPlayingArtist(artist.key, artist.value),
            child: Text(artists.length == 1
                ? locals.musicOpenArtist
                : locals.musicOpenNamedArtist(session.library.artistDisplayName(
                    MusicArtistIdentity.catalog(artist.key), artist.value)))),
    ];
    final profileChanges = app.stream.listen((_) => dismissStaleMenu());
    final playbackChanges = player.stream.listen((_) => dismissStaleMenu());
    try {
      final action = await _showSongPopup(context, entries);
      if (!context.mounted || !current() || action == null) return;
      if (action is _OpenPlayingArtist) {
        MusicScreen.openPlayingArtist(context, action.id,
            television: television, artistName: action.name);
      } else if (action == _PlayingSongAction.saveDevice && track != null) {
        await saveDeviceTrack(context, LocalMusicLibrary.instance, track,
            inPlayer: true, isCurrent: current);
      } else if (action == _PlayingSongAction.manageDevicePlaylists &&
          track != null) {
        await manageDeviceTrackPlaylists(
            context, LocalMusicLibrary.instance, track,
            inPlayer: true, isCurrent: current);
      } else if (action == _LibraryAction.setRingtone && ringtone != null) {
        await ringtone.set(context);
      } else if (action == _PlayingSongAction.rename && track != null) {
        await renameLocalMusicTrack(context, LocalMusicLibrary.instance, track,
            inPlayer: true, isCurrent: current);
      } else if (action == _LibraryAction.trackDetails && track != null) {
        final latest = localMusicTrackForPlayback(entry.videoId);
        if (latest != null) {
          await showMusicTrackDetails(context, device: latest, inPlayer: true);
        }
      } else if (action == _PlayingSongAction.shareFile && track != null) {
        await shareLocalMusicFile(context, localLibrary, track,
            isCurrent: () =>
                current() &&
                localLibrary.acceptsSessionSelection(localSelection));
      } else if (action == _PlayingSongAction.passageBookmarks) {
        final target = player.captureMusicPassage();
        if (target == null) return;
        await showMusicPassageBookmarksSheet(
          context,
          store: MusicPassageBookmarks(db, session._profileId),
          recordingId: target.recordingId,
          occurrenceId: target.occurrenceId,
          isCurrent: current,
          capturePosition: () {
            if (!current()) return null;
            final active = player.captureMusicPassage();
            return active?.occurrenceId == target.occurrenceId
                ? active?.position
                : null;
          },
          canJump: (bookmark) =>
              current() &&
              player.canJumpToMusicPassage(
                recordingId: bookmark.recordingId,
                occurrenceId: bookmark.occurrenceId,
                position: bookmark.position,
              ),
          jump: (bookmark) async =>
              current() &&
              await player.jumpToMusicPassage(
                recordingId: bookmark.recordingId,
                occurrenceId: bookmark.occurrenceId,
                position: bookmark.position,
              ),
        );
      } else if (action == _PlayingSongAction.localVideo && track != null) {
        await showLocalMusicVideoPairing(context,
            (profileId: app.state.profileId, recordingId: track.playbackId),
            isCurrent: () =>
                current() &&
                localMusicTrackForPlayback(entry.videoId)?.uri == track.uri);
      } else if (action == _LibraryAction.removeFromPlaylist &&
          source != null &&
          playlist != null &&
          playlistEntry != null) {
        await session.removeCurrentPlaylistEntry(
            source, playlist, playlistEntry,
            isCurrentEntry: () =>
                current() &&
                identical(player.currentLocalPlaylistEntry, playlistEntry));
      } else if (action == _LibraryAction.play) {
        player.play();
      } else if (action == _LibraryAction.timeline && onDevice) {
        await showMusicListeningTimeline(context,
            trackId: localMusicTrackId(entry.videoId),
            title: music.title,
            inPlayer: true);
      } else if (action == _LibraryAction.request) {
        addRequest(context, player, entry,
            recommendationSource: recommendationSource,
            inheritCurrentRecommendationSource: true);
      } else if (track != null &&
          (action == _LibraryAction.like || action == _LibraryAction.unlike)) {
        await session.setSongLiked(MusicLibraryEntry.deviceSong(track),
            liked: action == _LibraryAction.like);
      } else if (song != null && action is _LibraryAction) {
        await _apply(context, session, action, [song], null, null, downloads,
            inPlayer: true,
            recommendationSource: recommendationSource,
            isCurrent: current);
      } else if (file != null &&
          (action == _LibraryAction.playNext ||
              action == _LibraryAction.enqueue)) {
        await player.enqueueOfflineMusicCopies([file],
            next: action == _LibraryAction.playNext);
      }
    } catch (_) {
      if (context.mounted && current()) _showActionError(context);
    } finally {
      await profileChanges.cancel();
      await playbackChanges.cancel();
    }
  }

  static Future<T?> _showSongPopup<T>(
      BuildContext context, List<PopupMenuEntry<T>> items) async {
    final overlay = Navigator.of(context).overlay?.context.findRenderObject();
    if (overlay is! RenderBox || !overlay.hasSize) return null;
    final anchor = context.findRenderObject();
    // A sliver builder may supply its list's context instead of the row's box.
    final center = anchor is RenderBox && anchor.hasSize
        ? anchor.localToGlobal(anchor.size.center(Offset.zero),
            ancestor: overlay)
        : overlay.size.center(Offset.zero);
    return showMenu<T>(
        context: context,
        position: RelativeRect.fromRect(
            Rect.fromCenter(center: center, width: 0, height: 0),
            Offset.zero & overlay.size),
        items: items);
  }

  static Future<void> showSongMenu(BuildContext context, Video video,
      {Future<void> Function()? onPlay,
      String? localPlaylistId,
      PlaylistReference? playlistVisibility,
      bool inPlayer = false,
      PlaylistReference? recommendationSource,
      List<DownloadedVideo>? downloads,
      DownloadedVideo? Function()? resolveDownload,
      VoidCallback? onSelectSong,
      MusicSongRecommendation? recommendation}) async {
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent ||
        video.musicMetadata == null ||
        recommendation?.isCurrent() == false) {
      return;
    }
    final videos = List<Video>.unmodifiable([video]);
    final player = context.read<PlayerCubit?>();
    final queueGeneration = player?.playlistGeneration;
    final saved = downloads == null
        ? null
        : List<DownloadedVideo>.unmodifiable(downloads);
    bool current() =>
        context.mounted &&
        session.isCurrent &&
        recommendation?.isCurrent() != false;
    final ringtone = _ringtoneForSong(video, saved,
        isCurrent: current, resolveDownload: resolveDownload);
    ModalRoute<dynamic>? route;
    final changes = session.app.stream.listen((_) {
      if (!session.isCurrent && route?.isActive == true) {
        route!.navigator?.removeRoute(route!);
      }
    });
    try {
      final items = [
        ..._items(context, videos, localPlaylistId,
            downloads: saved,
            canHideInPlaylist: playlistVisibility != null,
            canSelectSong: onSelectSong != null,
            first: (child) => Builder(builder: (context) {
                  route ??= ModalRoute.of(context);
                  return inPlayer
                      ? PlayerModalBackHandler(child: child)
                      : child;
                })),
        if (ringtone != null)
          MusicRingtoneMenuItem(
              source: ringtone, value: _LibraryAction.setRingtone),
      ];
      final action = await (recommendation == null
          ? _showSongPopup(context, items)
          : showDialog<Enum>(
              context: context,
              useRootNavigator: false,
              builder: (_) => _RecommendedSongMenu(items, recommendation)));
      if (!context.mounted ||
          !session.isCurrent ||
          recommendation?.isCurrent() == false) {
        return;
      }
      if (action == _LibraryAction.selectSong) {
        onSelectSong?.call();
      } else if (action == _LibraryAction.setRingtone) {
        await ringtone?.set(context);
      } else if (action == _LibraryAction.hideInPlaylist &&
          playlistVisibility != null) {
        await MusicVisibility.forProfile(db, db.profileId)
            .setHiddenInPlaylist(playlistVisibility, video.videoId, true);
      } else if (action is _LibraryAction) {
        if (action == _LibraryAction.request &&
            (!identical(context.read<PlayerCubit?>(), player) ||
                player?.playlistGeneration != queueGeneration)) {
          return;
        }
        var currentDownloads = saved;
        if (resolveDownload != null &&
            (action == _LibraryAction.playNext ||
                action == _LibraryAction.enqueue ||
                action == _LibraryAction.trackDetails ||
                action == _LibraryAction.shareFile ||
                action == _LibraryAction.request)) {
          // The file can be removed or replaced while its menu is open.
          final current = resolveDownload();
          if (current == null ||
              !_matchesCompletedDownload(current, video.videoId)) {
            return;
          }
          final original = saved?.singleOrNull;
          if (action == _LibraryAction.shareFile &&
              (original == null ||
                  musicDownloadFingerprint(current) !=
                      musicDownloadFingerprint(original))) {
            return;
          }
          currentDownloads = [current];
        }
        await _apply(context, session, action, videos, localPlaylistId, onPlay,
            currentDownloads,
            inPlayer: inPlayer,
            recommendationSource: recommendationSource,
            isCurrent: recommendation?.isCurrent);
      } else if (action is _RecommendationAction && recommendation != null) {
        final reason = recommendation.reason;
        if (action == _RecommendationAction.snooze) {
          await recommendation.onSnooze?.call();
        } else if (action == _RecommendationAction.why && reason != null) {
          final explanation = recommendation._explanation(context, reason);
          route = explanation;
          await Navigator.of(context).push(explanation);
        } else {
          recommendation.onFeedback?.call(switch (action) {
            _RecommendationAction.more => RecommendationFeedback.like,
            _RecommendationAction.block => RecommendationFeedback.block,
            _ => RecommendationFeedback.notInterested,
          });
        }
      }
    } catch (_) {
      if (context.mounted && session.isCurrent) _showActionError(context);
    } finally {
      await changes.cancel();
    }
  }

  static Future<void> _manageSongPlaylists(
    BuildContext context,
    MusicLibrarySession session,
    Video song, {
    bool inPlayer = false,
    bool Function()? isCurrentSong,
    LocalMusicLibrary? deviceLibrary,
  }) async {
    final deviceIsCurrent = isLocalMusicPlaybackId(song.videoId)
        ? _devicePlaylistSourceGuard(
            deviceLibrary ?? LocalMusicLibrary.instance, song.videoId)
        : null;
    if (!context.mounted ||
        !session.isCurrent ||
        isCurrentSong?.call() == false ||
        deviceIsCurrent?.call() == false) {
      return;
    }
    // The open editor names this captured song even if playback advances.
    await showMusicPlaylistMembershipEditor(
      context,
      song: song,
      playlists: session.playlists,
      isProfileCurrent: () => session.isCurrent,
      profileChanges: session.app.stream,
      apply: (draft) => session._applyPlaylistMemberships(song, draft,
          isDeviceCurrent: deviceIsCurrent),
      inPlayer: inPlayer,
    );
  }

  static Future<bool> save(BuildContext context, List<Video> videos,
      {bool inPlayer = false, bool Function()? canSave}) async {
    if (videos.isEmpty) return false;
    return _showSave(context, videos, inPlayer: inPlayer, canSave: canSave);
  }

  static Future<void> savePlayingSong(BuildContext context, IdedVideo entry,
      {required bool Function() isCurrent}) async {
    final song = catalogMusicVideoForPlayback(entry);
    if (song != null) {
      await _showSave(context, [song], inPlayer: true, canSave: isCurrent);
    }
  }

  static Future<void> savePlaybackEntry(BuildContext context, IdedVideo entry,
      {required LocalMusicTrack? deviceTrack,
      required bool Function() isCurrent}) async {
    if (isLocalMusicPlaybackId(entry.videoId)) {
      if (deviceTrack != null) {
        await saveDeviceTrack(context, LocalMusicLibrary.instance, deviceTrack,
            inPlayer: true, isCurrent: isCurrent, showSongTitle: true);
      }
      return;
    }
    final song = catalogMusicVideoForPlayback(entry);
    if (song == null) return;
    await _showSave(context, [song],
        inPlayer: true,
        canSave: isCurrent,
        songTitle: song.musicMetadata?.title);
  }

  static Future<void> createPlaylist(BuildContext context,
      {List<Video> videos = const []}) async {
    await _showSave(context, videos, creating: true);
  }

  static Video? downloadedPlaylistSong(DownloadedVideo file) {
    final music = file.musicMetadata;
    if (music == null || isLocalMusicPlaybackId(file.videoId)) return null;
    return Video(
      videoId: file.videoId,
      title: music.title,
      author: music.artist,
      lengthSeconds: file.lengthSeconds,
      musicMetadata: music,
      videoThumbnails: music.thumbnails,
    );
  }

  static Future<void> manageDownloadedTrackPlaylists(
    BuildContext context,
    DownloadedVideo file, {
    required bool Function() isCurrent,
  }) async {
    final song = downloadedPlaylistSong(file);
    if (song == null || !_matchesCompletedDownload(file, song.videoId)) return;
    await _manageSongPlaylists(
      context,
      MusicLibrarySession(context.read<AppCubit>()),
      song,
      isCurrentSong: isCurrent,
    );
  }

  static Future<void> manageDeviceTrackPlaylists(
    BuildContext context,
    LocalMusicLibrary library,
    LocalMusicTrack track, {
    required bool Function() isCurrent,
    bool inPlayer = false,
  }) async {
    final video = devicePlaylistVideo(track);
    if (video == null || !isCurrent()) return;
    await _manageSongPlaylists(
      context,
      MusicLibrarySession(context.read<AppCubit>()),
      video,
      deviceLibrary: library,
      inPlayer: inPlayer,
      isCurrentSong: isCurrent,
    );
  }

  static bool Function() _devicePlaylistSourceGuard(
      LocalMusicLibrary library, String id) {
    final selection = library.selectionId;
    final profile = library.visibilityProfile;
    return () =>
        library.visibilityProfile == profile &&
        library.acceptsSessionSelection(selection) &&
        library.playlistTrackById(id, visibleOnly: true) != null;
  }

  static Future<void> saveDeviceTrack(
      BuildContext context, LocalMusicLibrary library, LocalMusicTrack track,
      {bool inPlayer = false,
      bool showSongTitle = false,
      required bool Function() isCurrent}) async {
    final video = devicePlaylistVideo(track);
    if (video == null) return;
    final currentDevice = _devicePlaylistSourceGuard(library, video.videoId);
    await _showSave(context, [video],
        inPlayer: inPlayer,
        songTitle: showSongTitle ? track.title : null,
        canSave: () => context.mounted && isCurrent() && currentDevice());
  }

  static Future<bool> _showSave(
    BuildContext context,
    List<Video> videos, {
    bool creating = false,
    bool inPlayer = false,
    String? songTitle,
    bool Function()? canSave,
  }) async {
    final app = context.read<AppCubit>();
    final session = MusicLibrarySession(app);
    if (!session.isCurrent || canSave?.call() == false) return false;
    final locals = AppLocalizations.of(context)!;
    final navigator = Navigator.of(context, rootNavigator: false);
    final selected = List<Video>.unmodifiable(videos);
    final route = DialogRoute<_SaveMusicResult>(
      context: context,
      builder: (_) => _SaveMusicDialog(
        session: session,
        videos: selected,
        creating: creating,
        inPlayer: inPlayer,
        songTitle: songTitle,
        canSave: canSave,
      ),
    );
    final changes = app.stream.listen((_) {
      if (!session.isCurrent && route.isActive && navigator.mounted) {
        navigator.removeRoute(route);
      }
    });
    try {
      final result = await navigator.push(route);
      if (result != null &&
          (!creating || selected.isNotEmpty) &&
          context.mounted &&
          session.isCurrent) {
        final message = result == _SaveMusicResult.saved
            ? locals.musicSavedToPlaylist
            : locals.musicPlaylistNoSongsAdded;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
      return result == _SaveMusicResult.saved;
    } finally {
      await changes.cancel();
    }
  }

  static Future<int> download(BuildContext context, List<Video> videos,
      {bool inPlayer = false, bool Function()? canDownload}) async {
    videos = videos.where((v) => !isLocalMusicPlaybackId(v.videoId)).toList();
    if (isTv || videos.isEmpty) return 0;
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent) return 0;
    final locals = AppLocalizations.of(context)!;
    try {
      final options = await DownloadModalSheet.showPlaylistOptions(context,
          musicAudioOnly: true, inPlayer: inPlayer);
      if (options == null ||
          !context.mounted ||
          !session.isCurrent ||
          canDownload?.call() == false) {
        return 0;
      }
      final count = await session.download(
          context.read<DownloadManagerCubit>(), videos,
          container: options.container,
          policy: options.musicPolicy,
          canStart: canDownload);
      if (context.mounted &&
          session.isCurrent &&
          canDownload?.call() != false) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text('${locals.downloadQueued}: ${locals.nVideos(count)}')));
      }
      return count;
    } catch (_) {
      if (context.mounted && session.isCurrent) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(locals.musicDownloadError)));
      }
      return 0;
    }
  }

  @override
  State<MusicLibraryActions> createState() => _MusicLibraryActionsState();
}

class _MusicLibraryActionsState extends State<MusicLibraryActions> {
  bool _busy = false;
  ({
    MusicLibrarySession session,
    MusicLibraryActions source,
    List<Video> videos,
    List<DownloadedVideo>? downloads,
    PlayerCubit? player,
    int? queueGeneration,
    MusicRingtoneSource? ringtone,
  })? _menu;
  ModalRoute<dynamic>? _menuRoute;
  StreamSubscription<AppState>? _sessionChanges;

  void _clearMenu() {
    _menu = null;
    _menuRoute = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sessionChanges?.cancel();
    _sessionChanges = context.read<AppCubit>().stream.listen((_) {
      if (!mounted) return;
      if (_menu?.session.isCurrent == false) {
        final route = _menuRoute;
        _clearMenu();
        if (route != null && route.isActive) {
          route.navigator?.removeRoute(route);
        }
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _sessionChanges?.cancel();
    super.dispose();
  }

  Future<void> _act(_LibraryAction action) async {
    final menu = _menu;
    final source = menu?.source ?? widget;
    final videos = menu?.videos ?? List<Video>.unmodifiable(source.videos);
    final downloads = menu == null ? source.downloads : menu.downloads;
    _clearMenu();
    final session =
        menu?.session ?? MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent || _busy) return;
    if (action == _LibraryAction.selectSong) {
      source.onSelectSong?.call();
      return;
    }
    if (action == _LibraryAction.request &&
        (menu == null ||
            !identical(context.read<PlayerCubit?>(), menu.player) ||
            menu.player?.playlistGeneration != menu.queueGeneration)) {
      return;
    }
    setState(() => _busy = true);
    try {
      final playlist = source.playlistVisibility;
      if (action == _LibraryAction.setRingtone) {
        await menu?.ringtone?.set(context);
      } else if (action == _LibraryAction.hideInPlaylist && playlist != null) {
        await MusicVisibility.forProfile(db, db.profileId)
            .setHiddenInPlaylist(playlist, videos.single.videoId, true);
      } else if (action == _LibraryAction.replacePlaylistEntry) {
        final reference = source.replacementPlaylist;
        if (reference == null || !reference.matchesOwner(db)) return;
        final entry = videos.single;
        final api = session._service;
        final playlist = api.getLocalPlaylistWithUniqueEntry(reference, entry);
        if (playlist == null || playlist.isEditLocked) return;
        final database = db;
        await showMusicPlaylistEntryReplacement(
          context,
          original: entry,
          isCurrent: () =>
              mounted && identical(db, database) && session.isCurrent,
          hasOfflineSource: (isCurrent) async {
            final saved =
                admittedMusicDownload(await prepareDownloadedPlaybackVideo(
              database: database,
              video: entry,
              server: session.app.state.server,
              audioOnly: true,
              isCurrent: isCurrent,
            ));
            if (saved == null || !isCurrent()) return false;
            final proof = await DownloadStorage()
                .musicFileProof(saved, verifyCompletion: true);
            if (proof == null) {
              throw StateError('The saved Music file could not be verified.');
            }
            return true;
          },
          onReplace: (replacement, isCurrent) async {
            final changed = await api.replaceLocalPlaylistMusicEntry(
                reference, entry, replacement,
                isCurrent: isCurrent);
            if (changed) session.library.notifyChanged();
            return changed;
          },
        );
      } else {
        await MusicLibraryActions._apply(context, session, action, videos,
            source.localPlaylistId, source.onPlay, downloads,
            inPlayer: source.inPlayer,
            recommendationSource: source.recommendationSource);
      }
    } catch (_) {
      if (mounted && session.isCurrent) _showActionError(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = MusicLibraryService.forProfile(db, db.profileId);
    return ListenableBuilder(
      listenable: library.changes,
      builder: (context, _) => _buildActions(context, library),
    );
  }

  Widget _buildActions(BuildContext context, MusicLibraryService library) {
    final locals = AppLocalizations.of(context)!;
    final enabled = !_busy && widget.videos.isNotEmpty;
    final song = MusicLibraryActions._song(widget.videos);
    final saved = song != null && library.contains(song.kind, song.id);
    final liked = song != null && library.isLiked(song.id);
    final bookmarkLabel = saved ? locals.musicRemoveSong : locals.musicSaveSong;
    final bookmarkAction =
        saved ? _LibraryAction.removeBookmark : _LibraryAction.saveBookmark;
    final removable = widget.localPlaylistId?.startsWith('local:') == true &&
        widget.videos.length == 1;
    if (widget.compact) {
      final recommendation = widget.recommendation;
      if (song != null && recommendation != null) {
        return IconButton(
            tooltip: locals.musicLibraryActions,
            style: widget.iconStyle,
            icon: const Icon(Icons.more_vert),
            onPressed: enabled
                ? () => MusicLibraryActions.showSongMenu(
                    context, widget.videos.single,
                    onPlay: widget.onPlay,
                    localPlaylistId: widget.localPlaylistId,
                    recommendationSource: widget.recommendationSource,
                    downloads: widget.downloads,
                    inPlayer: widget.inPlayer,
                    onSelectSong: widget.onSelectSong,
                    recommendation: recommendation)
                : null);
      }
      return PopupMenuButton<_LibraryAction>(
        tooltip: locals.musicLibraryActions,
        style: widget.iconStyle,
        enabled: enabled,
        onCanceled: _clearMenu,
        onSelected: _act,
        itemBuilder: (_) {
          final player = context.read<PlayerCubit?>();
          final session = MusicLibrarySession(context.read<AppCubit>());
          final videos = List<Video>.unmodifiable(widget.videos);
          final currentDownloads = widget.downloads;
          final downloads = currentDownloads == null
              ? null
              : List<DownloadedVideo>.unmodifiable(currentDownloads);
          final ringtone = MusicLibraryActions._ringtoneForSong(
              videos.singleOrNull, downloads,
              isCurrent: () => mounted && session.isCurrent);
          _menu = (
            session: session,
            source: widget,
            videos: videos,
            downloads: downloads,
            ringtone: ringtone,
            player: player,
            queueGeneration: player?.playlistGeneration,
          );
          return [
            ...MusicLibraryActions._items(
                context, videos, widget.localPlaylistId,
                downloads: downloads,
                canHideInPlaylist: widget.playlistVisibility != null,
                canReplacePlaylistEntry: widget.replacementPlaylist != null,
                canSelectSong: widget.onSelectSong != null,
                first: (child) => Builder(builder: (context) {
                      _menuRoute = ModalRoute.of(context);
                      return widget.inPlayer
                          ? PlayerModalBackHandler(child: child)
                          : child;
                    })),
            if (ringtone != null)
              MusicRingtoneMenuItem(
                  source: ringtone, value: _LibraryAction.setRingtone),
          ];
        },
      );
    }
    return Wrap(spacing: 8, runSpacing: 8, children: [
      if (song != null && widget.onSelectSong != null)
        OutlinedButton.icon(
            onPressed: enabled ? widget.onSelectSong : null,
            icon: const Icon(Icons.check_box_outline_blank),
            label: Text(locals.musicSelectSong)),
      if (song != null)
        OutlinedButton.icon(
            onPressed: enabled ? () => _act(bookmarkAction) : null,
            icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border),
            label: Text(bookmarkLabel)),
      if (song != null)
        OutlinedButton.icon(
            onPressed: enabled
                ? () =>
                    _act(liked ? _LibraryAction.unlike : _LibraryAction.like)
                : null,
            icon: Icon(liked ? Icons.favorite : Icons.favorite_border),
            label: Text(liked ? locals.musicUnlikeSong : locals.musicLikeSong)),
      OutlinedButton.icon(
          onPressed: enabled ? () => _act(_LibraryAction.save) : null,
          icon: const Icon(Icons.playlist_add),
          label: Text(locals.musicSaveToPlaylist)),
      if (MusicLibraryActions._canManageSongPlaylists(widget.videos))
        OutlinedButton.icon(
            onPressed:
                enabled ? () => _act(_LibraryAction.managePlaylists) : null,
            icon: const Icon(Icons.playlist_add_check),
            label: Text(locals.musicManageSongPlaylists)),
      if (removable)
        OutlinedButton.icon(
            onPressed:
                enabled ? () => _act(_LibraryAction.removeFromPlaylist) : null,
            icon: const Icon(Icons.playlist_remove),
            label: Text(locals.removeFromPlayList)),
      if (!isTv)
        OutlinedButton.icon(
            onPressed: enabled ? () => _act(_LibraryAction.download) : null,
            icon: const Icon(Icons.download),
            label: Text(locals.musicDownloadAudio)),
    ]);
  }
}

enum _SaveMusicResult { saved, unchanged }

class _SaveMusicDialog extends StatefulWidget {
  final MusicLibrarySession session;
  final List<Video> videos;
  final bool creating;
  final bool inPlayer;
  final String? songTitle;
  final bool Function()? canSave;

  const _SaveMusicDialog({
    required this.session,
    required this.videos,
    required this.inPlayer,
    this.creating = false,
    this.songTitle,
    this.canSave,
  });

  @override
  State<_SaveMusicDialog> createState() => _SaveMusicDialogState();
}

/// A bookmark saves only this public catalog identity and display metadata.
class MusicBookmarkButton extends StatefulWidget {
  final MusicLibraryEntry entry;
  final ButtonStyle? iconStyle;

  const MusicBookmarkButton({super.key, required this.entry, this.iconStyle});

  @override
  State<MusicBookmarkButton> createState() => _MusicBookmarkButtonState();
}

class _MusicBookmarkButtonState extends State<MusicBookmarkButton> {
  bool _busy = false;

  Future<void> _setSaved(bool saved) async {
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (_busy || !session.isCurrent) return;
    setState(() => _busy = true);
    try {
      await session.setBookmark(widget.entry, saved: saved);
    } catch (_) {
      if (mounted && session.isCurrent) _showActionError(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Legacy album bookmarks remain in storage and backups, but the Invidious
    // Music surface cannot browse or create YouTube Music catalog albums.
    if (widget.entry.kind == MusicLibraryKind.album) {
      return const SizedBox.shrink();
    }
    return BlocBuilder<AppCubit, AppState>(
      builder: (context, state) {
        final library = MusicLibraryService.forProfile(db, db.profileId);
        return ListenableBuilder(
          listenable: library.changes,
          builder: (context, _) {
            final saved = library.contains(widget.entry.kind, widget.entry.id);
            final locals = AppLocalizations.of(context)!;
            final label = switch (widget.entry.kind) {
              MusicLibraryKind.song =>
                saved ? locals.musicRemoveSong : locals.musicSaveSong,
              MusicLibraryKind.album =>
                saved ? locals.musicRemoveAlbum : locals.musicSaveAlbum,
              MusicLibraryKind.artist =>
                saved ? locals.musicRemoveArtist : locals.musicSaveArtist,
              MusicLibraryKind.playlist =>
                saved ? locals.musicRemovePlaylist : locals.musicSavePlaylist,
            };
            final toggle =
                _busy || state.globalLoading || state.sessionRecoveryRequired
                    ? null
                    : () => _setSaved(!saved);
            if (widget.iconStyle case final style?) {
              return IconButton(
                onPressed: toggle,
                icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border),
                tooltip: label,
                style: style,
              );
            }
            return OutlinedButton.icon(
                onPressed: toggle,
                icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border),
                label: Text(label));
          },
        );
      },
    );
  }
}

enum _SaveMusicPhase { idle, reviewing, writing }

enum _PlaylistDestinationSort { recentlyUpdated, trackCount }

class _PreviewSaveAction extends StatefulWidget {
  final MusicLibrarySession session;
  final MusicLibraryEntry entry;
  final bool Function() isCurrent;

  const _PreviewSaveAction({
    super.key,
    required this.session,
    required this.entry,
    required this.isCurrent,
  });

  @override
  State<_PreviewSaveAction> createState() => _PreviewSaveActionState();
}

class _PreviewSaveActionState extends State<_PreviewSaveAction> {
  bool _saving = false;
  bool _failed = false;

  bool get _saved =>
      widget.session.library.contains(widget.entry.kind, widget.entry.id);

  Future<void> _save(bool Function() isCurrent) async {
    if (!mounted || _saving || !isCurrent() || _saved) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await widget.session
          .setBookmark(widget.entry, saved: true, onlyIfAbsent: true);
    } catch (_) {
      if (mounted && isCurrent()) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final isCurrent = widget.isCurrent;
    return ListenableBuilder(
      listenable: widget.session.library.changes,
      builder: (context, _) {
        final saved = _saved;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_failed && !saved)
              Semantics(
                liveRegion: true,
                child: Text(locals.musicLibraryActionError),
              ),
            TextButton(
              onPressed: _saving || saved ? null : () => _save(isCurrent),
              child:
                  Text(saved ? locals.musicStatusSaved : locals.musicSaveSong),
            ),
          ],
        );
      },
    );
  }
}

class _SaveMusicDialogState extends State<_SaveMusicDialog> {
  final _name = TextEditingController();
  _PlaylistDestinationSort _sort = _PlaylistDestinationSort.recentlyUpdated;
  bool _creating = false;
  _SaveMusicPhase _phase = _SaveMusicPhase.idle;
  bool get _busy => _phase != _SaveMusicPhase.idle;
  bool get _writing => _phase == _SaveMusicPhase.writing;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _creating = widget.creating;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<bool?> _chooseDuplicates() async {
    final session = widget.session;
    final navigator = Navigator.of(context);
    final locals = AppLocalizations.of(context)!;
    final route = DialogRoute<bool>(
      context: context,
      builder: (_) {
        final dialog = AlertDialog(
          title: Text(locals.musicPlaylistDuplicateTitle),
          content: Text(locals.musicPlaylistDuplicateMessage),
          actions: [
            TextButton(
              onPressed: () => navigator.pop(),
              child: Text(locals.cancel),
            ),
            TextButton(
              onPressed: () => navigator.pop(false),
              child: Text(locals.musicPlaylistSkipDuplicates),
            ),
            TextButton(
              onPressed: () => navigator.pop(true),
              child: Text(locals.musicPlaylistAddDuplicates),
            ),
          ],
        );
        return widget.inPlayer
            ? PlayerModalBackHandler(priority: 5, child: dialog)
            : dialog;
      },
    );
    final changes = session.app.stream.listen((_) {
      if (!session.isCurrent && route.isActive && navigator.mounted) {
        navigator.removeRoute(route);
      }
    });
    try {
      return await navigator.push(route);
    } finally {
      await changes.cancel();
    }
  }

  Future<void> _save([String? playlistId]) async {
    if (_busy || !widget.session.isCurrent) return;
    if (widget.canSave?.call() == false) {
      Navigator.of(context).pop();
      return;
    }
    final name = _name.text.trim();
    if (playlistId == null && name.isEmpty) return;
    setState(() {
      _phase = _SaveMusicPhase.reviewing;
      _failed = false;
    });
    try {
      final destination = playlistId == null
          ? null
          : widget.session.playlists
              .firstWhere((playlist) => playlist.playlistId == playlistId);
      if (destination?.isEditLocked == true) {
        throw StateError('Playlist editing is locked');
      }
      final ids = <String>{
        for (final video in destination?.videos ?? const <Video>[])
          video.videoId,
      };
      final preserveOccurrences = widget.creating && widget.videos.isNotEmpty;
      final allowDuplicates = preserveOccurrences
          ? true
          : widget.videos.any((video) => !ids.add(video.videoId))
              ? await _chooseDuplicates()
              : false;
      if (allowDuplicates == null || !mounted || !widget.session.isCurrent) {
        return;
      }
      if (widget.canSave?.call() == false) {
        Navigator.of(context).pop();
        return;
      }
      setState(() => _phase = _SaveMusicPhase.writing);
      final _SaveMusicResult result;
      if (playlistId == null) {
        final created = await widget.session.createPlaylist(
          name,
          widget.videos,
          allowDuplicates: allowDuplicates,
          canSave: widget.canSave,
        );
        if (!created) return;
        result = _SaveMusicResult.saved;
      } else {
        final added = await widget.session.saveToPlaylist(
          playlistId,
          widget.videos,
          allowDuplicates: allowDuplicates,
          canSave: widget.canSave,
        );
        result =
            added > 0 ? _SaveMusicResult.saved : _SaveMusicResult.unchanged;
      }
      if (mounted && widget.session.isCurrent) {
        Navigator.of(context).pop(result);
      }
    } catch (_) {
      if (mounted && widget.session.isCurrent) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _phase = _SaveMusicPhase.idle);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    if (!widget.session.isCurrent) return const SizedBox.shrink();
    final destinations = _creating
        ? <(int, Playlist)>[]
        : widget.session.playlists.indexed.toList();
    destinations.sort((first, second) {
      final comparison = switch (_sort) {
        _PlaylistDestinationSort.recentlyUpdated =>
          (second.$2.updated ?? 0).compareTo(first.$2.updated ?? 0),
        _PlaylistDestinationSort.trackCount =>
          second.$2.videos.length.compareTo(first.$2.videos.length),
      };
      return comparison != 0 ? comparison : first.$1.compareTo(second.$1);
    });
    final dialog = AlertDialog(
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.creating
                ? locals.createNewPlaylist
                : locals.musicSaveToPlaylist,
          ),
          if (destinations.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(
                label: locals.searchSortBy,
                container: true,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final sort in _PlaylistDestinationSort.values)
                      ChoiceChip(
                        label: Text(switch (sort) {
                          _PlaylistDestinationSort.recentlyUpdated =>
                            locals.musicPlaylistSortRecentlyUpdated,
                          _PlaylistDestinationSort.trackCount =>
                            locals.musicPlaylistSortTrackCount,
                        }),
                        selected: _sort == sort,
                        onSelected:
                            _busy ? null : (_) => setState(() => _sort = sort),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.songTitle case final title? when title.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(title,
                        style: Theme.of(context).textTheme.titleMedium)),
              for (final (_, playlist) in destinations)
                ListTile(
                  key: ValueKey(playlist.playlistId),
                  enabled: !_busy && !playlist.isEditLocked,
                  title: Text(
                    playlist.playlistId == localWatchLaterId
                        ? locals.watchLater
                        : playlist.title,
                  ),
                  subtitle: Text(
                    playlist.isEditLocked
                        ? locals.musicPlaylistLocked
                        : locals.musicTrackCount(playlist.videos.length),
                  ),
                  onTap: () => _save(playlist.playlistId),
                ),
              if (_creating)
                TextField(
                  controller: _name,
                  autofocus: true,
                  enabled: !_busy,
                  decoration: InputDecoration(labelText: locals.playListName),
                  onSubmitted: (_) => _save(),
                )
              else
                TextButton.icon(
                  onPressed:
                      _busy ? null : () => setState(() => _creating = true),
                  icon: const Icon(Icons.add),
                  label: Text(locals.createNewPlaylist),
                ),
              if (_failed) Text(locals.musicLibraryActionError),
              if (_writing) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(locals.cancel),
        ),
        if (_creating)
          TextButton(
            onPressed: _busy ? null : () => _save(),
            child: Text(locals.add),
          ),
      ],
    );
    final content = PopScope<_SaveMusicResult>(
      canPop: !_writing,
      child: dialog,
    );
    return widget.inPlayer
        ? PlayerModalBackHandler(
            priority: 5,
            onBack: () => unawaited(Navigator.of(context).maybePop()),
            child: content,
          )
        : content;
  }
}
