import 'dart:async';
import 'dart:ui' show SemanticsRole;

import 'package:clipious/app/states/app.dart';
import 'package:clipious/content_filter/community_models.dart'
    show normalizeChannelId;
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/explicit_music_download.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/music_library_service.dart';
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
import 'music_listening_timeline.dart';

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
  final MusicLibraryService library;
  final RecommendationService _recommendations;
  final int _recommendationGeneration;

  MusicLibrarySession(this.app)
      : _initial = app.state,
        _profileId = db.profileId,
        _service = service,
        library = MusicLibraryService.forProfile(db, db.profileId),
        _recommendations = RecommendationService.forProfile(db, db.profileId),
        _recommendationGeneration =
            RecommendationService.forProfile(db, db.profileId)
                .generation(RecommendationDomain.music);

  bool get isCurrent =>
      !app.isClosed &&
      !app.state.globalLoading &&
      !app.state.sessionRecoveryRequired &&
      db.profileId == _profileId &&
      app.state.profileId == _initial.profileId &&
      app.state.sessionRevision == _initial.sessionRevision &&
      app.state.server == _initial.server;

  void _requireCurrent() {
    if (!isCurrent) throw StateError('The active profile changed.');
  }

  List<Playlist> get playlists {
    _requireCurrent();
    return _service.getLocalPlaylists();
  }

  Future<void> saveToPlaylist(String playlistId, List<Video> videos) async {
    _requireCurrent();
    if (!playlistId.startsWith('local:')) {
      throw ArgumentError('Choose a local playlist');
    }
    for (final video in _unique(videos)) {
      _requireCurrent();
      // Each existing service mutation captures its owner before yielding.
      await _service.addVideoToPlaylist(playlistId, video.videoId,
          video: video);
    }
    _requireCurrent();
    library.notifyChanged();
    // An explicit single-song save is useful feedback. A whole imported or
    // bulk-saved playlist must not look like listening to every recording.
    if (videos.length == 1 && videos.single.musicMetadata != null) {
      unawaited(_learnSaved(videos.single));
    }
  }

  Future<void> createPlaylist(String name, List<Video> videos) async {
    _requireCurrent();
    final id = await _service.createPlayList(name, 'local');
    _requireCurrent();
    if (id == null) throw StateError('Could not create playlist');
    await library.markLocalPlaylist(id);
    _requireCurrent();
    await saveToPlaylist(id, videos);
  }

  Future<void> removeFromPlaylist(String playlistId, String videoId) async {
    _requireCurrent();
    if (!playlistId.startsWith('local:')) {
      throw ArgumentError('Choose a local playlist');
    }
    // The existing local mutation captures its owner before yielding and uses
    // the video identity, never the index in Music's filtered playlist view.
    await _service.deleteUserPlaylistVideo(playlistId, videoId);
    _requireCurrent();
    library.notifyChanged();
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
      {required bool saved}) async {
    _requireCurrent();
    if (saved) {
      await library.save(entry);
    } else {
      await library.remove(entry.kind, entry.id);
    }
    _requireCurrent();
    if (saved && entry.kind == MusicLibraryKind.song) {
      unawaited(_learnSaved(entry.toVideo()));
    }
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
      {DownloadContainer? container, bool Function()? canStart}) async {
    _requireCurrent();
    if (isTv) return 0;
    final songs = _unique(videos);
    if ((songs.length > 1 || canStart != null) &&
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
  play,
  playNext,
  enqueue,
  saveBookmark,
  removeBookmark,
  save,
  removeFromPlaylist,
  download,
  timeline,
}

enum _RecommendationAction { why, more, less, block }

enum _PlayingSongAction { rename }

class _OpenPlayingArtist {
  final String id;

  const _OpenPlayingArtist(this.id);
}

enum _PlaylistSelectionAction {
  play,
  shuffle,
  next,
  append,
  save,
  download,
  removeDownloads
}

/// Resolves the current files for a Downloads selection in the supplied order.
typedef MusicSelectionDownloadResolver = List<DownloadedVideo>? Function(
    List<Video> playable);

class MusicPlaylistSelectionActions extends StatefulWidget {
  final List<Video> videos;
  final Future<void> Function(bool shuffle) onPlay;
  final VoidCallback onCompleted;
  final bool Function() isCurrent;
  final int? selectedCount;
  final MusicSelectionDownloadResolver? resolveDownloads;
  final Future<void> Function()? onRemoveDownloads;

  const MusicPlaylistSelectionActions({
    super.key,
    required this.videos,
    required this.onPlay,
    required this.onCompleted,
    required this.isCurrent,
    this.selectedCount,
    this.resolveDownloads,
    this.onRemoveDownloads,
  });

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
    return PopupMenuButton<Future<void> Function()>(
      key: const ValueKey('music-playlist-selection-actions'),
      tooltip: locals.musicPlaylistSelectionActions,
      enabled: !_busy &&
          (widget.videos.isNotEmpty || widget.onRemoveDownloads != null),
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
        final playable = catalog
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
        bool canEnqueue(List<DownloadedVideo>? files) =>
            player != null &&
            identical(context.read<PlayerCubit?>(), player) &&
            !player.isClosed &&
            player.state.isAudio &&
            (player.state.currentlyPlaying?.musicMetadata ??
                    player.state.offlineCurrentlyPlaying?.musicMetadata) !=
                null &&
            playable.isNotEmpty &&
            (resolve == null || files != null) &&
            player.canEnqueueMusicSongs(playable, downloads: files);
        final files = completedFiles();
        final fileFingerprints = files?.map(musicDownloadFingerprint).toList();
        final canPlay =
            playable.isNotEmpty && (resolve == null || files != null);
        final generation =
            canEnqueue(files) ? player!.playlistGeneration : null;
        List<Video> downloads() {
          if (isTv) return [];
          final playing = player?.state.currentlyPlaying;
          return MusicLibrarySession._unique(catalog)
              .where((song) =>
                  !song.downloadPlaybackOnly &&
                  !(playing?.videoId == song.videoId &&
                      playing?.downloadPlaybackOnly == true) &&
                  DownloadedVideo.isSafeFileId(song.videoId) &&
                  db.getDownloadByVideoId(song.videoId) == null)
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
                await source.onPlay(action == _PlaylistSelectionAction.shuffle);
              case _PlaylistSelectionAction.next:
              case _PlaylistSelectionAction.append:
                final currentFiles = completedFiles();
                if (generation == null ||
                    !canEnqueue(currentFiles) ||
                    player!.playlistGeneration != generation ||
                    (player.state.videos.isNotEmpty &&
                        !listEquals(
                            fileFingerprints,
                            currentFiles
                                ?.map(musicDownloadFingerprint)
                                .toList())) ||
                    !await player.enqueueMusicSongs(playable,
                        next: action == _PlaylistSelectionAction.next,
                        downloads: currentFiles)) {
                  throw StateError('The active music queue changed.');
                }
              case _PlaylistSelectionAction.save:
                if (!await MusicLibraryActions._showSave(
                    context, resolve == null ? catalog : playable,
                    canSave: () =>
                        current() &&
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
            }
            if (current()) source.onCompleted();
          } catch (_) {
            if (!context.mounted || !current()) return;
            final message = switch (action) {
              _PlaylistSelectionAction.save ||
              _PlaylistSelectionAction.download =>
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
          if (resolve == null || canPlay) ...[
            item(_PlaylistSelectionAction.play, locals.musicPlay, canPlay),
            item(
                _PlaylistSelectionAction.shuffle, locals.musicShuffle, canPlay),
            item(_PlaylistSelectionAction.next, locals.playNext,
                generation != null),
            item(_PlaylistSelectionAction.append, locals.addToQueueList,
                generation != null),
            item(_PlaylistSelectionAction.save, locals.musicSaveToPlaylist,
                catalog.isNotEmpty),
          ],
          if (resolve == null && downloads().isNotEmpty)
            item(_PlaylistSelectionAction.download, locals.musicDownloadAudio,
                true),
          if (source.onRemoveDownloads != null)
            item(_PlaylistSelectionAction.removeDownloads,
                locals.musicRemoveSelectedDownloads, true),
        ];
      },
    );
  }
}

/// Feedback is available only for songs the ranking service has scored.
class MusicSongRecommendation {
  final String reason;
  final ValueChanged<RecommendationFeedback> onFeedback;
  final bool Function() isCurrent;

  const MusicSongRecommendation(
      {required this.reason,
      required this.onFeedback,
      required this.isCurrent});

  DialogRoute<void> _explanation(BuildContext context) => DialogRoute<void>(
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

  const _RecommendedSongMenu(this.songItems);

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
      for (final (action, label) in [
        (_RecommendationAction.why, locals.recommendationWhy),
        (_RecommendationAction.more, locals.recommendationMoreLikeThis),
        (_RecommendationAction.less, locals.recommendationNotInterested),
        (_RecommendationAction.block, locals.recommendationBlockCreator),
      ])
        PopupMenuItem(value: action, child: Text(label)),
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
  final ButtonStyle? iconStyle;
  final bool inPlayer;
  final Future<void> Function()? onPlay;
  final List<DownloadedVideo>? downloads;
  final MusicSongRecommendation? recommendation;

  const MusicLibraryActions(
      {super.key,
      required this.videos,
      this.compact = true,
      this.localPlaylistId,
      this.iconStyle,
      this.inPlayer = false,
      this.onPlay,
      this.downloads,
      this.recommendation});

  static MusicLibraryEntry? _song(List<Video> videos) =>
      videos.length == 1 && videos.single.musicMetadata != null
          ? MusicLibraryEntry.song(videos.single)
          : null;

  static List<PopupMenuEntry<_LibraryAction>> _items(
      BuildContext context, List<Video> videos, String? playlistId,
      {required Widget Function(Widget) first,
      List<DownloadedVideo>? downloads,
      bool nowPlaying = false,
      bool showDownload = true}) {
    final locals = AppLocalizations.of(context)!;
    final song = _song(videos);
    final library = MusicLibraryService.forProfile(db, db.profileId);
    final saved = song != null && library.contains(song.kind, song.id);
    final player = context.read<PlayerCubit?>();
    final idle = player != null &&
        (!player.state.hasVideo ||
            player.state.isHidden ||
            player.state.isClosing);
    final canQueue = player != null &&
        (idle || player.canEnqueueMusicSongs(videos, downloads: downloads));
    final addLabel =
        nowPlaying ? locals.addToPlaylist : locals.musicSaveToPlaylist;
    return [
      if (song != null) ...[
        PopupMenuItem(
            key: const ValueKey('music-song-play'),
            value: _LibraryAction.play,
            child: first(Text(locals.musicPlay))),
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
        const PopupMenuDivider(),
        PopupMenuItem(
            value: saved
                ? _LibraryAction.removeBookmark
                : _LibraryAction.saveBookmark,
            child: Text(saved ? locals.musicRemoveSong : locals.musicSaveSong)),
      ],
      PopupMenuItem(
          value: _LibraryAction.save,
          child: song == null ? first(Text(addLabel)) : Text(addLabel)),
      if (playlistId?.startsWith('local:') == true && videos.length == 1)
        PopupMenuItem(
            value: _LibraryAction.removeFromPlaylist,
            child: Text(locals.removeFromPlayList)),
      if (!isTv && showDownload)
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

  static Future<void> _apply(
      BuildContext context,
      MusicLibrarySession session,
      _LibraryAction action,
      List<Video> videos,
      String? playlistId,
      Future<void> Function()? onPlay,
      List<DownloadedVideo>? downloads,
      {required bool inPlayer,
      bool Function()? isCurrent}) async {
    if (!context.mounted || !session.isCurrent) return;
    if (action == _LibraryAction.play ||
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
            next: action == _LibraryAction.playNext, downloads: downloads)) {
          throw StateError('The active queue changed.');
        }
      } else if (action == _LibraryAction.play && onPlay != null) {
        await onPlay();
      } else if (downloads != null) {
        await player.playOfflineVideos(downloads, fromMusic: true);
      } else {
        await MusicScreen.playTracks(context, videos);
      }
    } else if (action == _LibraryAction.saveBookmark ||
        action == _LibraryAction.removeBookmark) {
      final song = _song(videos);
      if (song != null) {
        await session.setBookmark(song,
            saved: action == _LibraryAction.saveBookmark);
      }
    } else if (action == _LibraryAction.save) {
      await _showSave(context, videos, inPlayer: inPlayer, canSave: isCurrent);
    } else if (action == _LibraryAction.removeFromPlaylist) {
      if (playlistId != null && videos.length == 1) {
        await session.removeFromPlaylist(playlistId, videos.single.videoId);
      }
    } else if (action == _LibraryAction.timeline) {
      final song = _song(videos);
      if (song != null) {
        await showMusicListeningTimeline(context,
            trackId: song.id, title: song.title, inPlayer: inPlayer);
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
    final song = onDevice
        ? null
        : video ??
            Video(
                videoId: entry.videoId,
                title: music.title,
                author: music.artist,
                lengthSeconds: file?.lengthSeconds,
                musicMetadata: music,
                videoThumbnails: music.thumbnails);
    final downloads = file != null && !onDevice ? [file] : null;
    final track = onDevice ? localMusicTrackForPlayback(entry.videoId) : null;
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
        if (track?.canRename == true &&
            track?.fileName != null &&
            !LocalMusicLibrary.instance.busy)
          PopupMenuItem(
              value: _PlayingSongAction.rename,
              child: Text(locals.localMusicRename)),
        PopupMenuItem(
            key: const ValueKey('music-song-listening-timeline'),
            value: _LibraryAction.timeline,
            child: Text(locals.musicListeningTimeline)),
      ],
      if (title != null)
        PopupMenuItem(
            key: const ValueKey('music-player-remove-from-playlist'),
            value: _LibraryAction.removeFromPlaylist,
            child: Text(locals.musicRemoveFromNamedPlaylist(title))),
      for (final artist in artists.entries)
        PopupMenuItem(
            key: ValueKey(('music-player-open-artist', artist.key)),
            value: _OpenPlayingArtist(artist.key),
            child: Text(artists.length == 1
                ? locals.musicOpenArtist
                : locals.musicOpenNamedArtist(artist.value))),
    ];
    final profileChanges = app.stream.listen((_) => dismissStaleMenu());
    final playbackChanges = player.stream.listen((_) => dismissStaleMenu());
    try {
      final action = await _showSongPopup(context, entries);
      if (!context.mounted || !current() || action == null) return;
      if (action is _OpenPlayingArtist) {
        MusicScreen.openPlayingArtist(context, action.id,
            television: television);
      } else if (action == _PlayingSongAction.rename && track != null) {
        await renameLocalMusicTrack(context, LocalMusicLibrary.instance, track,
            inPlayer: true, isCurrent: current);
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
      } else if (song != null && action is _LibraryAction) {
        await _apply(context, session, action, [song], null, null, downloads,
            inPlayer: true, isCurrent: current);
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
      bool inPlayer = false,
      List<DownloadedVideo>? downloads,
      DownloadedVideo? Function()? resolveDownload,
      MusicSongRecommendation? recommendation}) async {
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent ||
        video.musicMetadata == null ||
        recommendation?.isCurrent() == false) {
      return;
    }
    final videos = List<Video>.unmodifiable([video]);
    final saved = downloads == null
        ? null
        : List<DownloadedVideo>.unmodifiable(downloads);
    ModalRoute<dynamic>? route;
    final changes = session.app.stream.listen((_) {
      if (!session.isCurrent && route?.isActive == true) {
        route!.navigator?.removeRoute(route!);
      }
    });
    try {
      final items = _items(context, videos, localPlaylistId,
          downloads: saved,
          first: (child) => Builder(builder: (context) {
                route ??= ModalRoute.of(context);
                return inPlayer ? PlayerModalBackHandler(child: child) : child;
              }));
      final action = await (recommendation == null
          ? _showSongPopup(context, items)
          : showDialog<Enum>(
              context: context,
              useRootNavigator: false,
              builder: (_) => _RecommendedSongMenu(items)));
      if (!context.mounted ||
          !session.isCurrent ||
          recommendation?.isCurrent() == false) {
        return;
      }
      if (action is _LibraryAction) {
        var currentDownloads = saved;
        if (resolveDownload != null &&
            (action == _LibraryAction.playNext ||
                action == _LibraryAction.enqueue)) {
          // The file can be removed or replaced while its menu is open.
          final current = resolveDownload();
          if (current == null ||
              !_matchesCompletedDownload(current, video.videoId)) {
            return;
          }
          currentDownloads = [current];
        }
        await _apply(context, session, action, videos, localPlaylistId, onPlay,
            currentDownloads,
            inPlayer: inPlayer);
      } else if (action is _RecommendationAction && recommendation != null) {
        if (action == _RecommendationAction.why) {
          final explanation = recommendation._explanation(context);
          route = explanation;
          await Navigator.of(context).push(explanation);
        } else {
          recommendation.onFeedback(switch (action) {
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

  static Future<void> save(BuildContext context, List<Video> videos,
      {bool inPlayer = false}) async {
    if (videos.isEmpty) return;
    await _showSave(context, videos, inPlayer: inPlayer);
  }

  static Future<void> createPlaylist(BuildContext context) async {
    await _showSave(context, const [], creating: true);
  }

  static Future<bool> _showSave(BuildContext context, List<Video> videos,
      {bool creating = false,
      bool inPlayer = false,
      bool Function()? canSave}) async {
    final app = context.read<AppCubit>();
    final session = MusicLibrarySession(app);
    if (!session.isCurrent || canSave?.call() == false) return false;
    final locals = AppLocalizations.of(context)!;
    final navigator = Navigator.of(context, rootNavigator: false);
    final route = DialogRoute<bool>(
        context: context,
        builder: (_) {
          final dialog = _SaveMusicDialog(
              session: session,
              videos: videos,
              creating: creating,
              canSave: canSave);
          return inPlayer
              ? PlayerModalBackHandler(priority: 5, child: dialog)
              : dialog;
        });
    final changes = app.stream.listen((_) {
      if (!session.isCurrent && route.isActive && navigator.mounted) {
        navigator.removeRoute(route);
      }
    });
    try {
      final saved = await navigator.push(route);
      if (saved == true && !creating && context.mounted && session.isCurrent) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(locals.musicSavedToPlaylist)));
      }
      return saved == true;
    } finally {
      await changes.cancel();
    }
  }

  static Future<int> download(BuildContext context, List<Video> videos,
      {bool inPlayer = false, bool Function()? canDownload}) async {
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
          container: options.container, canStart: canDownload);
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
    setState(() => _busy = true);
    try {
      await MusicLibraryActions._apply(context, session, action, videos,
          source.localPlaylistId, source.onPlay, downloads,
          inPlayer: source.inPlayer);
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
                    downloads: widget.downloads,
                    inPlayer: widget.inPlayer,
                    recommendation: recommendation)
                : null);
      }
      return PopupMenuButton<_LibraryAction>(
        tooltip: locals.musicLibraryActions,
        style: widget.iconStyle,
        enabled: enabled,
        onOpened: () {
          _menu = (
            session: MusicLibrarySession(context.read<AppCubit>()),
            source: widget,
            videos: List<Video>.unmodifiable(widget.videos),
            downloads: widget.downloads == null
                ? null
                : List<DownloadedVideo>.unmodifiable(widget.downloads!),
          );
        },
        onCanceled: _clearMenu,
        onSelected: _act,
        itemBuilder: (_) => MusicLibraryActions._items(
            context, widget.videos, widget.localPlaylistId,
            downloads: widget.downloads,
            first: (child) => Builder(builder: (context) {
                  _menuRoute = ModalRoute.of(context);
                  return widget.inPlayer
                      ? PlayerModalBackHandler(child: child)
                      : child;
                })),
      );
    }
    return Wrap(spacing: 8, runSpacing: 8, children: [
      if (song != null)
        OutlinedButton.icon(
            onPressed: enabled ? () => _act(bookmarkAction) : null,
            icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border),
            label: Text(bookmarkLabel)),
      OutlinedButton.icon(
          onPressed: enabled ? () => _act(_LibraryAction.save) : null,
          icon: const Icon(Icons.playlist_add),
          label: Text(locals.musicSaveToPlaylist)),
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

class _SaveMusicDialog extends StatefulWidget {
  final MusicLibrarySession session;
  final List<Video> videos;
  final bool creating;
  final bool Function()? canSave;

  const _SaveMusicDialog(
      {required this.session,
      required this.videos,
      this.creating = false,
      this.canSave});

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
                icon: Icon(saved ? Icons.favorite : Icons.favorite_border),
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

class _SaveMusicDialogState extends State<_SaveMusicDialog> {
  final _name = TextEditingController();
  bool _creating = false;
  bool _saving = false;
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

  Future<void> _save([String? playlistId]) async {
    if (_saving || !widget.session.isCurrent) return;
    if (widget.canSave?.call() == false) {
      Navigator.of(context).pop(false);
      return;
    }
    if (playlistId == null && _name.text.trim().isEmpty) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      if (playlistId == null) {
        await widget.session.createPlaylist(_name.text, widget.videos);
      } else {
        await widget.session.saveToPlaylist(playlistId, widget.videos);
      }
      if (mounted && widget.session.isCurrent) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted && widget.session.isCurrent) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    if (!widget.session.isCurrent) return const SizedBox.shrink();
    return AlertDialog(
      title: Text(widget.creating
          ? locals.createNewPlaylist
          : locals.musicSaveToPlaylist),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final playlist
                in widget.creating ? <Playlist>[] : widget.session.playlists)
              ListTile(
                enabled: !_saving &&
                    !widget.videos.every((video) => playlist.videos
                        .any((saved) => saved.videoId == video.videoId)),
                title: Text(playlist.playlistId == localWatchLaterId
                    ? locals.watchLater
                    : playlist.title),
                subtitle: Text(locals.onDevice),
                onTap: () => _save(playlist.playlistId),
              ),
            if (_creating)
              TextField(
                controller: _name,
                autofocus: true,
                enabled: !_saving,
                decoration: InputDecoration(labelText: locals.playListName),
                onSubmitted: (_) => _save(),
              )
            else
              TextButton.icon(
                  onPressed:
                      _saving ? null : () => setState(() => _creating = true),
                  icon: const Icon(Icons.add),
                  label: Text(locals.createNewPlaylist)),
            if (_failed) Text(locals.musicLibraryActionError),
            if (_saving) const LinearProgressIndicator(),
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: Text(locals.cancel)),
        if (_creating)
          TextButton(
              onPressed: _saving ? null : () => _save(),
              child: Text(locals.add)),
      ],
    );
  }
}
