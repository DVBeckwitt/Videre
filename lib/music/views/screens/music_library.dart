import 'dart:math' as math;

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/downloads/views/components/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/song_artwork.dart';
import 'package:clipious/music/views/components/community_music_artwork.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/views/components/music_details_dialog.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/components/local_music_folder.dart';
import 'package:clipious/music/views/components/music_playlist_resume.dart';
import 'package:clipious/music/views/components/takeout_import_dialog.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/podcasts/views/podcast_library.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/views/components/playlist_information.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/utils/views/components/channel_avatar.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/video_watch_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

enum _LibraryFilter {
  all,
  playlists,
  songs,
  onDevice,
  channels,
  downloads,
  podcasts
}

enum _LibrarySort { saved, title }

typedef _LibraryItem = ({Playlist? playlist, MusicLibraryEntry? bookmark});

/// The Music home's local Library body. The home owns its navigation and chrome.
class MusicLibraryPage extends StatefulWidget {
  const MusicLibraryPage({super.key});

  @override
  State<MusicLibraryPage> createState() => _MusicLibraryPageState();
}

class _MusicLibraryPageState extends State<MusicLibraryPage> {
  _LibraryFilter _filter = isTv ? _LibraryFilter.playlists : _LibraryFilter.all;
  _LibrarySort _sort = _LibrarySort.saved;
  bool _grid = !isTv;
  String? _playlistId;

  Future<void> _play(List<Video> videos,
      {PlaylistReference? reference,
      int? startIndex,
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

  Future<void> _openBookmark(
      MusicLibraryEntry entry, List<_LibraryItem> items) async {
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent || entry.kind == MusicLibraryKind.album) return;
    if (entry.kind == MusicLibraryKind.song) {
      final songs = [
        for (final item in items)
          if (item.bookmark case final song?
              when song.kind == MusicLibraryKind.song)
            song.toVideo(),
      ];
      final index = songs.indexWhere((song) => song.videoId == entry.id);
      if (index >= 0) await _play(songs, startIndex: index);
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
                instanceOnly: true,
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

  Widget _bookmarkActions(
      MusicLibraryEntry entry, Future<void> Function() onOpen) {
    final locals = AppLocalizations.of(context)!;
    final removeLabel = switch (entry.kind) {
      MusicLibraryKind.song => locals.musicRemoveSong,
      MusicLibraryKind.album => locals.musicRemoveAlbum,
      MusicLibraryKind.artist => locals.musicRemoveArtist,
      MusicLibraryKind.playlist => locals.musicRemovePlaylist,
    };
    return entry.kind == MusicLibraryKind.song
        ? MusicLibraryActions(videos: [entry.toVideo()], onPlay: onOpen)
        : IconButton(
            tooltip: removeLabel,
            onPressed: () => _removeBookmark(entry),
            icon: const Icon(Icons.bookmark_remove_outlined));
  }

  Widget _bookmarkArtwork(MusicLibraryEntry? entry, Widget fallback) {
    if (entry == null || entry.kind != MusicLibraryKind.song) return fallback;
    return CommunityMusicArtwork(
        videoId: entry.id,
        music: entry.toVideo().musicMetadata!,
        durationSeconds: entry.durationSeconds,
        fallback: fallback);
  }

  Widget _bookmark(MusicLibraryEntry entry, Future<void> Function() onOpen) {
    return ListTile(
        key: ValueKey('music-saved-${entry.kind.name}-${entry.id}'),
        leading: entry.kind == MusicLibraryKind.artist
            ? ChannelAvatar(
                name: entry.title,
                images: entry.thumbnails,
                size: 52,
                instanceOnly: true)
            : SizedBox.square(
                dimension: 52,
                child:
                    _bookmarkArtwork(entry, _artwork(entry.displayThumbnails))),
        title: Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: entry.subtitle.isEmpty
            ? null
            : Text(entry.subtitle,
                maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: _bookmarkActions(entry, onOpen),
        onLongPress: entry.kind != MusicLibraryKind.song
            ? null
            : () => MusicLibraryActions.showSongMenu(context, entry.toVideo(),
                onPlay: onOpen),
        onTap: onOpen);
  }

  String _label(_LibraryFilter filter, AppLocalizations locals) =>
      switch (filter) {
        _LibraryFilter.all => locals.musicLibrary,
        _LibraryFilter.playlists => locals.musicPlaylists,
        _LibraryFilter.songs => locals.musicSongs,
        _LibraryFilter.onDevice => locals.onDevice,
        _LibraryFilter.podcasts => locals.podcasts,
        _LibraryFilter.channels => locals.channels,
        _LibraryFilter.downloads => locals.downloads,
      };

  Widget _localPlaylist(Playlist playlist, MusicLibraryService library) {
    final locals = AppLocalizations.of(context)!;
    final savedCovers = library.coversBySongId;
    final instanceUrl = context.read<AppCubit>().state.server?.url;
    final songs = <Video>[];
    for (final video in playlist.videos) {
      final music = video.musicMetadata;
      if (music == null) continue;
      final covers = savedCovers[video.videoId];
      songs.add(covers == null
          ? video
          : video.copyWith(musicMetadata: music.withThumbnails(covers)));
    }
    final reference = PlaylistReference.forPlaylist(
        playlist, db.forProfile(library.profileId));
    return CustomScrollView(slivers: [
      SliverToBoxAdapter(
          child: Column(children: [
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: PlaylistInformation(playlist: playlist, reference: reference),
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
      ])),
      songs.isEmpty
          ? SliverFillRemaining(hasScrollBody: false, child: _empty())
          : SliverList.builder(
              itemCount: songs.length,
              itemBuilder: (_, index) {
                final song = songs[index];
                final music = song.musicMetadata!;
                return ListTile(
                    leading: SizedBox.square(
                      dimension: 52,
                      child: Stack(fit: StackFit.expand, children: [
                        CommunityMusicArtwork(
                            videoId: song.videoId,
                            music: music,
                            durationSeconds: song.lengthSeconds,
                            fallback: _artwork(displaySongThumbnails(
                                song.videoId,
                                music.thumbnails,
                                song.videoThumbnails,
                                artTrack: music.isArtTrack,
                                instanceUrl: instanceUrl))),
                        VideoWatchProgress(videoId: song.videoId),
                      ]),
                    ),
                    title: Text(music.title),
                    subtitle: Text(music.artist),
                    trailing: MusicLibraryActions(
                        videos: [song],
                        localPlaylistId: playlist.playlistId,
                        onPlay: () => _play(songs,
                            reference: reference, startIndex: index)),
                    onLongPress: () => MusicLibraryActions.showSongMenu(
                        context, song,
                        localPlaylistId: playlist.playlistId,
                        onPlay: () => _play(songs,
                            reference: reference, startIndex: index)),
                    onTap: () =>
                        _play(songs, reference: reference, startIndex: index));
              }),
    ]);
  }

  Widget _catalogLibrary(MusicLibraryService library) {
    final theme = Theme.of(context);
    final locals = AppLocalizations.of(context)!;
    final playlists = service
        .getLocalPlaylists(database: db.forProfile(library.profileId))
        .where(library.isMusicPlaylist)
        .toList();
    final selected = playlists
        .where((playlist) => playlist.playlistId == _playlistId)
        .firstOrNull;
    if (selected != null) return _localPlaylist(selected, library);
    final kind = switch (_filter) {
      _LibraryFilter.all => null,
      _LibraryFilter.playlists => MusicLibraryKind.playlist,
      _LibraryFilter.songs => MusicLibraryKind.song,
      _LibraryFilter.channels => MusicLibraryKind.artist,
      _LibraryFilter.downloads => MusicLibraryKind.song,
      _LibraryFilter.podcasts => MusicLibraryKind.song,
      _LibraryFilter.onDevice => null,
    };
    final entries = library.entries
        .where((entry) =>
            entry.kind != MusicLibraryKind.album &&
            (kind == null || entry.kind == kind))
        .toList();
    final hasPlaylists =
        _filter == _LibraryFilter.playlists || _filter == _LibraryFilter.all;
    final items = <_LibraryItem>[
      if (hasPlaylists)
        for (final playlist in playlists) (playlist: playlist, bookmark: null),
      for (final entry in entries) (playlist: null, bookmark: entry),
    ];
    final shortcuts = <_LibraryFilter>[
      if (_filter == _LibraryFilter.all) _LibraryFilter.songs,
      if (_filter == _LibraryFilter.all &&
          context.watch<DownloadManagerCubit?>() != null)
        _LibraryFilter.downloads,
    ];
    if (_sort == _LibrarySort.title) {
      items.sort((first, second) {
        final comparison = _itemTitle(first)
            .toLowerCase()
            .compareTo(_itemTitle(second).toLowerCase());
        return comparison != 0
            ? comparison
            : _itemKey(first).value.compareTo(_itemKey(second).value);
      });
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsetsDirectional.only(start: 18, end: 8),
        child: Row(children: [
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: PopupMenuButton<_LibrarySort>(
                key: const ValueKey('music-library-sort'),
                tooltip: locals.searchSortBy,
                initialValue: _sort,
                onSelected: (value) => setState(() => _sort = value),
                itemBuilder: (_) => [
                  PopupMenuItem(
                      value: _LibrarySort.saved,
                      child: Text(locals.musicLibrarySavedOrder)),
                  PopupMenuItem(
                      value: _LibrarySort.title,
                      child: Text(locals.musicLibraryTitleOrder)),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Flexible(
                      child: Text(
                          _sort == _LibrarySort.saved
                              ? locals.musicLibrarySavedOrder
                              : locals.musicLibraryTitleOrder,
                          style: theme.textTheme.titleSmall),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.arrow_downward_rounded, size: 16),
                  ]),
                ),
              ),
            ),
          ),
          if (hasPlaylists)
            IconButton(
                tooltip: locals.createNewPlaylist,
                onPressed: () => MusicLibraryActions.createPlaylist(context),
                icon: const Icon(Icons.playlist_add_rounded)),
          IconButton(
              key: const ValueKey('music-library-layout'),
              tooltip: _grid
                  ? locals.musicLibraryListView
                  : locals.musicLibraryGridView,
              onPressed: () => setState(() => _grid = !_grid),
              icon: Icon(_grid ? Icons.view_list : Icons.grid_view)),
        ]),
      ),
      if (_filter == _LibraryFilter.songs &&
          entries.any((entry) => entry.needsSongDetails))
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: () => showMusicDetailsDialog(context, entries),
              icon: const Icon(Icons.auto_fix_high_outlined),
              label: Text(locals.musicLoadSongDetails),
            ),
          ),
        ),
      Expanded(
        child: items.isEmpty && shortcuts.isEmpty
            ? _empty()
            : _collection(items, shortcuts, library),
      ),
    ]);
  }

  ValueKey<String> _itemKey(_LibraryItem item) => item.playlist != null
      ? ValueKey('music-local-${item.playlist!.playlistId}')
      : ValueKey(
          'music-saved-${item.bookmark!.kind.name}-${item.bookmark!.id}');

  String _itemTitle(_LibraryItem item) =>
      item.playlist?.playlistId == localWatchLaterId
          ? AppLocalizations.of(context)!.watchLater
          : item.playlist?.title ?? item.bookmark!.title;

  Future<void> _openItem(_LibraryItem item, List<_LibraryItem> items) async {
    if (item.playlist case final playlist?) {
      setState(() => _playlistId = playlist.playlistId);
    } else {
      await _openBookmark(item.bookmark!, items);
    }
  }

  String _shortcutTitle(_LibraryFilter shortcut, AppLocalizations locals) =>
      shortcut == _LibraryFilter.songs
          ? locals.musicSavedSongs
          : locals.downloads;

  IconData _shortcutIcon(_LibraryFilter shortcut) =>
      shortcut == _LibraryFilter.songs
          ? Icons.favorite_rounded
          : Icons.cloud_download_rounded;

  ValueKey<String> _shortcutKey(_LibraryFilter shortcut) =>
      ValueKey('music-library-shortcut-${shortcut.name}');

  void _selectFilter(_LibraryFilter filter) => setState(() {
        _filter = filter;
        _playlistId = null;
      });

  Widget _collection(List<_LibraryItem> items, List<_LibraryFilter> shortcuts,
      MusicLibraryService library) {
    // Both lazy layouts retain an item's element when sorting or removing an
    // earlier row. This also keeps keyboard/TV focus on the surviving item.
    final indices = <Key, int>{
      for (var index = 0; index < shortcuts.length; index++)
        _shortcutKey(shortcuts[index]): index,
      for (var index = 0; index < items.length; index++)
        _itemKey(items[index]): index + shortcuts.length,
    };
    final count = items.length + shortcuts.length;
    final locals = AppLocalizations.of(context)!;
    if (!_grid) {
      return ListView.builder(
          key: PageStorageKey('music-library-list-${_filter.name}'),
          itemCount: count,
          findChildIndexCallback: (key) => indices[key],
          itemBuilder: (_, index) {
            if (index < shortcuts.length) {
              final shortcut = shortcuts[index];
              return ListTile(
                  key: _shortcutKey(shortcut),
                  leading: Icon(_shortcutIcon(shortcut)),
                  title: Text(_shortcutTitle(shortcut, locals)),
                  onTap: () => _selectFilter(shortcut));
            }
            final item = items[index - shortcuts.length];
            if (item.bookmark case final bookmark?) {
              return _bookmark(bookmark, () => _openItem(item, items));
            }
            return ListTile(
                key: _itemKey(item),
                leading: const Icon(Icons.queue_music),
                title: Text(_itemTitle(item)),
                subtitle: Text(AppLocalizations.of(context)!.onDevice),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openItem(item, items));
          });
    }
    final savedCovers = library.coversBySongId;
    return LayoutBuilder(builder: (context, constraints) {
      final theme = Theme.of(context).textTheme;
      final scaler = MediaQuery.textScalerOf(context);
      const padding = 12.0;
      const spacing = 18.0;
      final minimumWidth = math.max(140.0, scaler.scale(112));
      final columns = math.min(
          6,
          math.max(
              1,
              ((constraints.maxWidth - 2 * padding + spacing) /
                      (minimumWidth + spacing))
                  .floor()));
      final width =
          (constraints.maxWidth - 2 * padding - (columns - 1) * spacing) /
              columns;
      final titleHeight = scaler.scale(theme.titleMedium!.fontSize!) *
          (theme.titleMedium!.height ?? 1.5);
      final subtitleHeight = scaler.scale(theme.bodyMedium!.fontSize!) *
          (theme.bodyMedium!.height ?? 1.4);
      return GridView.builder(
          key: PageStorageKey('music-library-grid-${_filter.name}'),
          padding: const EdgeInsets.fromLTRB(padding, 12, padding, 16),
          itemCount: count,
          findChildIndexCallback: (key) => indices[key],
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: spacing,
              mainAxisSpacing: 14,
              mainAxisExtent: width + titleHeight * 2 + subtitleHeight + 10),
          itemBuilder: (_, index) => index < shortcuts.length
              ? _gridShortcut(shortcuts[index], locals)
              : _gridItem(items[index - shortcuts.length], savedCovers,
                  () => _openItem(items[index - shortcuts.length], items)));
    });
  }

  Widget _gridShortcut(_LibraryFilter shortcut, AppLocalizations locals) {
    final colors = Theme.of(context).colorScheme;
    return _gridCard(
      key: _shortcutKey(shortcut),
      title: _shortcutTitle(shortcut, locals),
      artwork: ColoredBox(
          color: colors.surfaceContainerHighest,
          child: Icon(_shortcutIcon(shortcut),
              size: 64, color: colors.onSurfaceVariant)),
      artworkRadius: 25,
      onOpen: () => _selectFilter(shortcut),
    );
  }

  Widget _gridItem(
      _LibraryItem item,
      Map<String, List<ImageObject>> savedCovers,
      Future<void> Function() onOpen) {
    final entry = item.bookmark;
    final song = item.playlist?.videos.firstOrNull;
    final music = song?.musicMetadata;
    final images = entry?.displayThumbnails ??
        (song == null
            ? const <ImageObject>[]
            : displaySongThumbnails(
                song.videoId,
                savedCovers[song.videoId] ?? music?.thumbnails ?? const [],
                song.videoThumbnails,
                artTrack: music?.isArtTrack ?? false,
                instanceUrl: context.read<AppCubit>().state.server?.url));
    final artist = entry?.kind == MusicLibraryKind.artist;
    final playlist =
        item.playlist != null || entry?.kind == MusicLibraryKind.playlist;
    final plays = entry?.kind == MusicLibraryKind.song;
    final colors = Theme.of(context).colorScheme;
    return _gridCard(
      key: _itemKey(item),
      title: _itemTitle(item),
      subtitle: entry?.subtitle ?? AppLocalizations.of(context)!.onDevice,
      artworkRadius: artist ? 300 : 7,
      artwork: _bookmarkArtwork(
          entry,
          images.isEmpty
              ? ColoredBox(
                  color: colors.surfaceContainerHighest,
                  child: Icon(
                      artist
                          ? Icons.person_rounded
                          : playlist
                              ? Icons.queue_music_rounded
                              : Icons.music_note_rounded,
                      size: 48,
                      color: colors.onSurfaceVariant))
              : Thumbnail(
                  images: images,
                  instanceOnly: true,
                  decoration: const BoxDecoration())),
      action: entry == null ? null : _bookmarkActions(entry, onOpen),
      plays: plays,
      onOpen: onOpen,
      onLongPress: entry?.kind != MusicLibraryKind.song
          ? null
          : () => MusicLibraryActions.showSongMenu(context, entry!.toVideo(),
              onPlay: onOpen),
    );
  }

  Widget _gridCard({
    required Key key,
    required String title,
    required Widget artwork,
    required double artworkRadius,
    required VoidCallback onOpen,
    VoidCallback? onLongPress,
    String subtitle = '',
    Widget? action,
    bool plays = false,
  }) {
    final theme = Theme.of(context);
    return Material(
      key: key,
      type: MaterialType.transparency,
      child: Builder(builder: (context) {
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onOpen,
          onLongPress: onLongPress,
          onFocusChange: (focused) {
            if (focused) Scrollable.ensureVisible(context, alignment: 0.5);
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: Stack(fit: StackFit.expand, children: [
                  ExcludeSemantics(
                      child: ClipRRect(
                          borderRadius: BorderRadius.circular(artworkRadius),
                          child: artwork)),
                  if (plays)
                    const PositionedDirectional(
                        end: 7,
                        bottom: 7,
                        child: ExcludeSemantics(
                            child: CircleAvatar(
                                radius: 17,
                                backgroundColor: Colors.black54,
                                foregroundColor: Colors.white,
                                child: Icon(Icons.play_arrow_rounded)))),
                  if (action != null)
                    PositionedDirectional(
                        end: 4,
                        top: 4,
                        child: Material(
                            shape: const CircleBorder(),
                            color: Colors.black54,
                            child: Theme(
                                data: theme.copyWith(
                                    iconTheme: theme.iconTheme
                                        .copyWith(color: Colors.white),
                                    iconButtonTheme: IconButtonThemeData(
                                        style: IconButton.styleFrom(
                                            foregroundColor: Colors.white))),
                                child: action))),
                ]),
              ),
              const SizedBox(height: 6),
              Text(title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              if (subtitle.isNotEmpty)
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        );
      }),
    );
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
        Future<void> playFrom(DownloadedVideo selected) =>
            _downloadAction(selected, (_) {
              final completed =
                  videos.where((video) => video.downloadComplete).toList();
              return context.read<PlayerCubit>().playOfflineVideos(completed,
                  startIndex: completed.indexOf(selected));
            });
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
                    onLongPress: !video.downloadComplete
                        ? null
                        : () => MusicLibraryActions.showSongMenu(
                            context,
                            Video(
                                videoId: video.videoId,
                                title: video.musicMetadata!.title,
                                author: video.musicMetadata!.artist,
                                lengthSeconds: video.lengthSeconds,
                                musicMetadata: video.musicMetadata,
                                videoThumbnails:
                                    video.musicMetadata!.thumbnails),
                            downloads: [video],
                            onPlay: () => playFrom(video)),
                    onTap:
                        !video.downloadComplete ? null : () => playFrom(video),
                    trailing: video.downloadComplete
                        ? MusicDownloadExportAction(video: video, compact: true)
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
          final theme = Theme.of(context);
          final colors = theme.colorScheme;
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
                            padding: const EdgeInsetsDirectional.only(
                                start: 16, end: 6),
                            child: Row(children: [
                              Expanded(
                                  child: Semantics(
                                      header: true,
                                      child: Text(locals.musicLibrary,
                                          style: theme.textTheme.titleLarge))),
                              IconButton(
                                  tooltip: locals.takeoutImport,
                                  icon: const Icon(Icons.file_upload_outlined),
                                  onPressed: state.globalLoading ||
                                          state.sessionRecoveryRequired
                                      ? null
                                      : () async {
                                          final imported =
                                              await showTakeoutImport(context);
                                          if (mounted && imported == true) {
                                            setState(() {
                                              _filter = _LibraryFilter.songs;
                                              _playlistId = null;
                                            });
                                          }
                                        }),
                            ])),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(children: [
                            for (final filter in _LibraryFilter.values)
                              if (filter != _LibraryFilter.all &&
                                  (filter != _LibraryFilter.onDevice ||
                                      supportsLocalMusicFolders) &&
                                  (!isTv || filter != _LibraryFilter.downloads))
                                Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: ChoiceChip(
                                        key: ValueKey(
                                            'music-library-tab-${filter.name}'),
                                        label: Text(_label(filter, locals)),
                                        labelStyle: theme.textTheme.labelLarge
                                            ?.copyWith(
                                                color: _filter == filter
                                                    ? colors.onInverseSurface
                                                    : colors.onSurfaceVariant),
                                        labelPadding:
                                            const EdgeInsets.symmetric(
                                                horizontal: 9),
                                        showCheckmark: false,
                                        shape: const StadiumBorder(),
                                        side: BorderSide.none,
                                        backgroundColor:
                                            colors.surfaceContainerHighest,
                                        selectedColor: colors.inverseSurface,
                                        selected: _filter == filter,
                                        onSelected: (selected) => _selectFilter(
                                            selected || isTv
                                                ? filter
                                                : _LibraryFilter.all))),
                          ]),
                        ),
                        Expanded(
                            child: _filter == _LibraryFilter.onDevice
                                ? const LocalMusicFolder.library()
                                : state.globalLoading ||
                                        state.sessionRecoveryRequired
                                    ? const Center(
                                        child: CircularProgressIndicator())
                                    : _filter == _LibraryFilter.podcasts
                                        ? PodcastLibraryPage(
                                            key: ValueKey(
                                                'podcasts-${db.profileId}-${state.sessionRevision}'))
                                        : _filter == _LibraryFilter.downloads &&
                                                !isTv
                                            ? _downloads()
                                            : _catalogLibrary(library)),
                      ],
                    )),
          );
        },
      );
}
