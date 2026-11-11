import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/components/music_playlist_resume.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/utils/views/components/channel_avatar.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/video_watch_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

enum _LibraryFilter { playlists, songs, channels, downloads }

/// The Music home's local Library body. The home owns its navigation and chrome.
class MusicLibraryPage extends StatefulWidget {
  const MusicLibraryPage({super.key});

  @override
  State<MusicLibraryPage> createState() => _MusicLibraryPageState();
}

class _MusicLibraryPageState extends State<MusicLibraryPage> {
  _LibraryFilter _filter = _LibraryFilter.playlists;
  String? _playlistId;

  Future<void> _play(List<Video> videos,
      {PlaylistReference? reference,
      int startIndex = 0,
      Duration startAt = Duration.zero}) async {
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent || videos.isEmpty) return;
    try {
      await MusicScreen.playTracks(context, videos,
          reference: reference, startIndex: startIndex, startAt: startAt);
    } catch (_) {
      if (mounted && session.isCurrent) _error();
    }
  }

  void _error() => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(AppLocalizations.of(context)!.musicPlaybackError)));

  Future<void> _openBookmark(MusicLibraryEntry entry) async {
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent || entry.kind == MusicLibraryKind.album) return;
    if (entry.kind == MusicLibraryKind.song) {
      await _play([entry.toVideo()]);
      return;
    }
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => MusicScreen(
              artistId: entry.kind == MusicLibraryKind.artist ? entry.id : null,
              playlistId:
                  entry.kind == MusicLibraryKind.playlist ? entry.id : null,
            )));
    if (mounted && session.isCurrent) setState(() {});
  }

  Widget _artwork(List<ImageObject> images,
          {IconData icon = Icons.music_note}) =>
      SizedBox.square(
        dimension: 52,
        child: images.isEmpty
            ? Icon(icon)
            : Thumbnail(
                images: images,
                decoration:
                    BoxDecoration(borderRadius: BorderRadius.circular(8))),
      );

  Widget _empty() => Center(
      child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(AppLocalizations.of(context)!.musicLibraryEmpty,
              textAlign: TextAlign.center)));

  Future<void> _removeBookmark(MusicLibraryEntry entry) async {
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent) return;
    try {
      await session.library.remove(entry.kind, entry.id);
    } catch (_) {
      if (mounted && session.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(AppLocalizations.of(context)!.musicLibraryActionError)));
      }
    }
  }

  Widget _bookmark(MusicLibraryEntry entry) {
    final locals = AppLocalizations.of(context)!;
    final removeLabel = switch (entry.kind) {
      MusicLibraryKind.song => locals.musicRemoveSong,
      MusicLibraryKind.album => locals.musicRemoveAlbum,
      MusicLibraryKind.artist => locals.musicRemoveArtist,
      MusicLibraryKind.playlist => locals.musicRemovePlaylist,
    };
    return ListTile(
        key: ValueKey('music-saved-${entry.kind.name}-${entry.id}'),
        leading: entry.kind == MusicLibraryKind.artist
            ? ChannelAvatar(
                name: entry.title, images: entry.thumbnails, size: 52)
            : _artwork(entry.thumbnails),
        title: Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: entry.subtitle.isEmpty
            ? null
            : Text(entry.subtitle,
                maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: entry.kind == MusicLibraryKind.song
            ? MusicLibraryActions(videos: [entry.toVideo()])
            : Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                    tooltip: removeLabel,
                    onPressed: () => _removeBookmark(entry),
                    icon: const Icon(Icons.bookmark_remove_outlined)),
                const Icon(Icons.chevron_right),
              ]),
        onTap: () => _openBookmark(entry));
  }

  String _label(_LibraryFilter filter, AppLocalizations locals) =>
      switch (filter) {
        _LibraryFilter.playlists => locals.musicPlaylists,
        _LibraryFilter.songs => locals.musicSongs,
        _LibraryFilter.channels => locals.channels,
        _LibraryFilter.downloads => locals.downloads,
      };

  Widget _localPlaylist(Playlist playlist) {
    final locals = AppLocalizations.of(context)!;
    final songs =
        playlist.videos.where((video) => video.musicMetadata != null).toList();
    final reference = PlaylistReference.forPlaylist(playlist, db);
    return Column(children: [
      ListTile(
        leading: IconButton(
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() => _playlistId = null)),
        title: Text(playlist.playlistId == localWatchLaterId
            ? locals.watchLater
            : playlist.title),
        subtitle: Text(locals.onDevice),
      ),
      if (songs.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
                onPressed: () => _play(songs, reference: reference),
                icon: const Icon(Icons.play_arrow),
                label: Text(locals.musicPlayAll)),
            MusicPlaylistResume(
                reference: reference,
                videos: songs,
                onPlay: (index, position) => _play(songs,
                    reference: reference,
                    startIndex: index,
                    startAt: position)),
            MusicLibraryActions(videos: songs, compact: false),
          ]),
        ),
      Expanded(
        child: songs.isEmpty
            ? _empty()
            : ListView.builder(
                itemCount: songs.length,
                itemBuilder: (_, index) {
                  final song = songs[index];
                  final music = song.musicMetadata!;
                  return ListTile(
                      leading: SizedBox.square(
                        dimension: 52,
                        child: Stack(fit: StackFit.expand, children: [
                          _artwork(music.thumbnails.isNotEmpty
                              ? music.thumbnails
                              : song.videoThumbnails),
                          VideoWatchProgress(videoId: song.videoId),
                        ]),
                      ),
                      title: Text(music.title),
                      subtitle: Text(music.artist),
                      trailing: MusicLibraryActions(
                          videos: [song], localPlaylistId: playlist.playlistId),
                      onTap: () => _play(songs,
                          reference: reference, startIndex: index));
                }),
      ),
    ]);
  }

  Widget _catalogLibrary(MusicLibraryService library) {
    final locals = AppLocalizations.of(context)!;
    final playlists = service
        .getLocalPlaylists(database: db.forProfile(library.profileId))
        .where(library.isMusicPlaylist)
        .toList();
    final selected = playlists
        .where((playlist) => playlist.playlistId == _playlistId)
        .firstOrNull;
    if (selected != null) return _localPlaylist(selected);
    final kind = switch (_filter) {
      _LibraryFilter.playlists => MusicLibraryKind.playlist,
      _LibraryFilter.songs => MusicLibraryKind.song,
      _LibraryFilter.channels => MusicLibraryKind.artist,
      _LibraryFilter.downloads => MusicLibraryKind.song,
    };
    final entries =
        library.entries.where((entry) => entry.kind == kind).toList();
    if (_filter != _LibraryFilter.playlists) {
      return entries.isEmpty
          ? _empty()
          : ListView(children: entries.map(_bookmark).toList());
    }
    return Column(children: [
      Align(
          alignment: Alignment.centerLeft,
          child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton.icon(
                  onPressed: () => MusicLibraryActions.createPlaylist(context),
                  icon: const Icon(Icons.add),
                  label: Text(locals.createNewPlaylist)))),
      Expanded(
        child: playlists.isEmpty && entries.isEmpty
            ? _empty()
            : ListView(children: [
                for (final playlist in playlists)
                  ListTile(
                      key: ValueKey('music-local-${playlist.playlistId}'),
                      leading: const Icon(Icons.queue_music),
                      title: Text(playlist.playlistId == localWatchLaterId
                          ? locals.watchLater
                          : playlist.title),
                      subtitle: Text(locals.onDevice),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () =>
                          setState(() => _playlistId = playlist.playlistId)),
                ...entries.map(_bookmark),
              ]),
      ),
    ]);
  }

  Future<void> _downloadAction(DownloadedVideo video,
      Future<void> Function(DownloadManagerCubit) action) async {
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent || video.profileId != session.library.profileId) {
      return;
    }
    try {
      await action(context.read<DownloadManagerCubit>());
    } catch (_) {
      if (mounted && session.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.musicDownloadError)));
      }
    }
  }

  Widget _downloads() =>
      BlocBuilder<DownloadManagerCubit, DownloadManagerState>(
          builder: (context, state) {
        final locals = AppLocalizations.of(context)!;
        final videos = state.videos
            .where((video) =>
                video.profileId == db.profileId &&
                video.audioOnly &&
                video.musicMetadata != null)
            .toList();
        if (videos.isEmpty) return _empty();
        return ListView.builder(
            itemCount: videos.length,
            itemBuilder: (context, index) {
              final video = videos[index];
              final paused = state.pausedVideoIds.contains(video.videoId);
              final retry =
                  video.downloadFailed || video.authenticationRequired;
              final progress = state.downloadProgresses[video.videoId];
              final status = video.downloadComplete
                  ? video.musicMetadata!.artist
                  : video.authenticationRequired
                      ? locals.downloadSignInRequired
                      : video.storageFailed
                          ? locals.downloadFolderError
                          : video.downloadFailed
                              ? locals.videoFailedDownloadRetry
                              : paused
                                  ? locals.downloadPaused
                                  : state.waitingForWifi
                                      ? locals.downloadsWaitingForWifi
                                      : locals.downloadQueued;
              return Column(children: [
                ListTile(
                    key: ValueKey('music-download-${video.videoId}'),
                    leading: Icon(video.downloadComplete
                        ? Icons.offline_pin
                        : Icons.downloading),
                    title: Text(video.musicMetadata!.title),
                    subtitle: Text(status),
                    onTap: !video.downloadComplete
                        ? null
                        : () => _downloadAction(
                            video,
                            (_) => context
                                .read<PlayerCubit>()
                                .playOfflineVideos([video])),
                    trailing: video.downloadComplete
                        ? null
                        : IconButton(
                            tooltip: retry
                                ? locals.retry
                                : paused
                                    ? locals.resumeDownload
                                    : locals.pauseDownload,
                            icon: Icon(retry
                                ? Icons.refresh
                                : paused
                                    ? Icons.play_arrow
                                    : Icons.pause),
                            onPressed: () => _downloadAction(
                                video,
                                (manager) => retry || paused
                                    ? manager.retryDownload(video)
                                    : manager.pauseDownload(video)))),
                if (!video.downloadComplete && progress != null && !paused)
                  LinearProgressIndicator(
                      value: progress.total > 0
                          ? progress.count / progress.total
                          : null),
              ]);
            });
      });

  @override
  Widget build(BuildContext context) => BlocConsumer<AppCubit, AppState>(
        listenWhen: (before, after) =>
            before.profileId != after.profileId ||
            before.sessionRevision != after.sessionRevision ||
            before.server != after.server ||
            before.globalLoading != after.globalLoading,
        listener: (context, state) => setState(() => _playlistId = null),
        builder: (context, state) {
          // Retained home pages rebuild when visible again, including changes
          // made through the application's existing local playlist screens.
          final active = TickerMode.of(context);
          final locals = AppLocalizations.of(context)!;
          final library = MusicLibraryService.forProfile(db, db.profileId);
          return PopScope(
            canPop: _playlistId == null || !active,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && _playlistId != null && active) {
                setState(() => _playlistId = null);
              }
            },
            child: ListenableBuilder(
                listenable: library.changes,
                builder: (context, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(locals.musicLibrary,
                                style:
                                    Theme.of(context).textTheme.headlineSmall)),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(children: [
                            for (final filter in _LibraryFilter.values)
                              if (!isTv || filter != _LibraryFilter.downloads)
                                Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: ChoiceChip(
                                        label: Text(_label(filter, locals)),
                                        selected: _filter == filter,
                                        onSelected: (_) => setState(() {
                                              _filter = filter;
                                              _playlistId = null;
                                            }))),
                          ]),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                            child: state.globalLoading ||
                                    state.sessionRecoveryRequired
                                ? const Center(
                                    child: CircularProgressIndicator())
                                : _filter == _LibraryFilter.downloads && !isTv
                                    ? _downloads()
                                    : _catalogLibrary(library)),
                      ],
                    )),
          );
        },
      );
}
