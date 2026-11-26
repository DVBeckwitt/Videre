import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../downloads/services/explicit_music_download.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../player/models/local_music_playback.dart';
import '../../../utils/views/components/thumbnail.dart';
import '../../../videos/models/video.dart';
import '../../../videos/states/history.dart';
import '../../../videos/views/components/history_video.dart';
import '../../models/device_playlist_track.dart';
import '../../models/music_library_entry.dart';
import '../../models/on_device_music_entry.dart';
import '../../models/song_artwork.dart';
import '../../services/local_music_library.dart';
import '../../services/music_listening_history.dart';
import '../components/local_music_folder.dart' show supportsLocalMusicFolders;
import '../components/music_collection_panes.dart';
import '../components/music_derived_song_selection.dart';
import '../components/music_library_actions.dart';
import '../components/music_song_selection_bar.dart';
import 'music.dart';

enum _AutomaticCollection {
  liked(Icons.favorite_outline),
  recent(Icons.history),
  mostPlayed(Icons.bar_chart);

  final IconData icon;
  const _AutomaticCollection(this.icon);

  String label(AppLocalizations locals) => switch (this) {
        liked => locals.musicLikedSongs,
        recent => locals.musicRecentlyPlayed,
        mostPlayed => locals.musicMostPlayed,
      };
}

class MusicAutomaticCollectionsPage extends StatelessWidget {
  final MusicLibrarySession session;
  final bool showLikes;

  const MusicAutomaticCollectionsPage(
      {super.key, required this.session, this.showLikes = false});

  @override
  Widget build(BuildContext context) {
    if (showLikes) {
      return _AutomaticCollectionPage(
          session: session, collection: _AutomaticCollection.liked);
    }
    final locals = AppLocalizations.of(context)!;
    return Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
      },
      child: Scaffold(
        appBar: AppBar(title: Text(locals.musicAutomaticCollections)),
        body: SafeArea(
          child: BlocBuilder<AppCubit, AppState>(
            bloc: session.app,
            builder: (context, _) => session.isCurrent
                ? ListView(
                    children: [
                      for (final collection in _AutomaticCollection.values)
                        ListTile(
                          key: ValueKey('music-automatic-${collection.name}'),
                          leading: Icon(collection.icon),
                          title: Text(collection.label(locals)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            if (!session.isCurrent) return;
                            Navigator.of(context).push<void>(MaterialPageRoute(
                                builder: (_) => _AutomaticCollectionPage(
                                    session: session, collection: collection)));
                          },
                        ),
                    ],
                  )
                : Center(child: Text(locals.musicSourceUnavailable)),
          ),
        ),
      ),
    );
  }
}

class _AutomaticCollectionPage extends StatefulWidget {
  const _AutomaticCollectionPage(
      {required this.session, required this.collection});

  final MusicLibrarySession session;
  final _AutomaticCollection collection;

  @override
  State<_AutomaticCollectionPage> createState() =>
      _AutomaticCollectionPageState();
}

class _AutomaticCollectionPageState extends State<_AutomaticCollectionPage> {
  late final _database = db.forProfile(widget.session.library.profileId);
  late final _history =
      MusicListeningHistory.forProfile(db, widget.session.library.profileId);
  final _deviceLibrary = LocalMusicLibrary.instance;
  late final _changes = Listenable.merge([
    if (_liked) widget.session.library.changes else _history.changes,
    _deviceLibrary,
  ]);
  int _playRequest = 0;

  bool get _liked => widget.collection == _AutomaticCollection.liked;
  bool get _current =>
      widget.session.isCurrent && (ModalRoute.isCurrentOf(context) ?? true);

  @override
  void initState() {
    super.initState();
    if (supportsLocalMusicFolders && widget.session.isCurrent) {
      final hasDeviceSongs = _liked
          ? widget.session.library.likedSongs
              .any((song) => isLocalMusicPlaybackId(song.id))
          : _historyTracks()
              .any((event) => event.source == MusicListeningSource.device);
      if (hasDeviceSongs) unawaited(_loadDeviceTracks());
    }
  }

  Future<void> _loadDeviceTracks() async {
    await _deviceLibrary.initialize();
    if (!mounted || !widget.session.isCurrent) return;
    await _deviceLibrary.revalidate();
    if (mounted &&
        widget.session.isCurrent &&
        _deviceLibrary.enabled &&
        !_deviceLibrary.unavailable &&
        !_deviceLibrary.loaded) {
      await _deviceLibrary.refresh();
    }
  }

  List<MusicListeningEvent> _historyTracks() {
    final List<MusicListeningEvent> events;
    try {
      events = _history.events();
    } on UnsupportedError {
      return const [];
    }
    final countPlays = widget.collection == _AutomaticCollection.mostPlayed;
    final tracks = <String, ({MusicListeningEvent latest, int count})>{};
    // The producer supplies newest-first events and deduplicates imports.
    for (final event in events) {
      if (countPlays && event.isLegacy) continue;
      final previous = tracks[event.trackId];
      tracks[event.trackId] = (
        latest: previous?.latest ?? event,
        count: (previous?.count ?? 0) + 1,
      );
    }
    final ordered = tracks.values.toList();
    if (countPlays) {
      ordered.sort((a, b) {
        final count = b.count.compareTo(a.count);
        if (count != 0) return count;
        final date = b.latest.playedAt.compareTo(a.latest.playedAt);
        return date != 0 ? date : a.latest.trackId.compareTo(b.latest.trackId);
      });
    }
    return ordered.map((track) => track.latest).toList();
  }

  Future<void> _play(Future<void> Function() start) async {
    if (!mounted || !_current) return;
    final request = ++_playRequest;
    try {
      await start();
    } catch (_) {
      if (mounted && _current && request == _playRequest) {
        final locals = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(locals.musicPlaybackError)));
      }
    }
  }

  void _playSongs(List<Video> songs, String title,
      {int index = 0, bool shuffle = false}) {
    final queue = shuffle ? (songs.toList()..shuffle()) : songs;
    unawaited(_play(() => MusicScreen.playTracks(context, queue,
        queueTitle: title, startIndex: index)));
  }

  OnDeviceMusicEntry? _deviceEntry(MusicLibraryEntry song) {
    if (!_deviceLibrary.enabled || _deviceLibrary.unavailable) return null;
    final track = _deviceLibrary.visibleTrackById(song.id);
    return track == null ? null : OnDeviceMusicEntry.device(track);
  }

  void _playDevice(List<MusicLibraryEntry> songs, String title,
      {String? from, bool shuffle = false}) {
    if (!mounted || !_current) return;
    final queue = songs.map(_deviceEntry).nonNulls.toList();
    if (shuffle) queue.shuffle();
    final index =
        from == null ? 0 : queue.indexWhere((entry) => entry.id == from);
    if (index < 0 || queue.isEmpty) return;
    // A TV player pushes its own route before it opens the device queue.
    // The profile check remains valid while that route covers this page.
    unawaited(_play(() => MusicScreen.playOnDeviceTracks(context, queue,
        queueTitle: title,
        startIndex: index,
        isCurrent: () => mounted && widget.session.isCurrent)));
  }

  Future<void> _unlike(MusicLibraryEntry song) async {
    if (!mounted || !_current) return;
    try {
      await widget.session.setSongLiked(song, liked: false);
    } catch (_) {
      if (mounted && _current) {
        final locals = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(locals.musicLibraryActionError)));
      }
    }
  }

  Future<bool> _removeLikes(List<String> ids, bool Function() isCurrent) async {
    final locals = AppLocalizations.of(context)!;
    final confirmed = await widget.session.showDialog<bool>(
      context,
      (context) => AlertDialog(
        title: Text(locals.musicRemoveSelectedLikedSongs),
        content: Text(locals.musicRemoveSelectedLikedSongsConfirm(ids.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(locals.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(locals.musicRemoveSelectedLikedSongs),
          ),
        ],
      ),
    );
    return confirmed == true &&
        isCurrent() &&
        await widget.session.library
            .removeLikedSongs(ids, isCurrent: isCurrent);
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final title = widget.collection.label(locals);
    return Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
      },
      child: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: SafeArea(
          child: BlocBuilder<AppCubit, AppState>(
            bloc: widget.session.app,
            builder: (context, _) => ListenableBuilder(
              listenable: _changes,
              builder: (context, _) {
                if (!widget.session.isCurrent) {
                  return Center(child: Text(locals.musicSourceUnavailable));
                }
                return _content(locals, title);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(AppLocalizations locals, String title) {
    final liked = _liked
        ? widget.session.library.likedSongs
        : const <MusicLibraryEntry>[];
    final tracks = <({Video video, bool legacyDownload})>[];
    final deviceSongs = <MusicLibraryEntry>[];
    if (_liked) {
      for (final song in liked) {
        if (isLocalMusicPlaybackId(song.id)) {
          deviceSongs.add(song);
        } else {
          tracks.add((video: song.toVideo(), legacyDownload: false));
        }
      }
    } else {
      for (final event in _historyTracks()) {
        final row = event.entry;
        if (event.source == MusicListeningSource.device) {
          deviceSongs.add(MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: event.trackId,
            title: row.title,
            subtitle: row.author ?? '',
          ));
          continue;
        }
        final video = row.toVideo();
        final download = row.replayDownload(_database);
        if (download == null) {
          tracks.add((video: video, legacyDownload: false));
        } else {
          final fingerprint = musicDownloadFingerprint(download);
          final ready = readyMusicDownload(_database, download.videoId,
              fingerprint: fingerprint);
          // Older non-music downloads can still use their original history
          // replay path. The normal Music queue only pins music downloads.
          tracks.add((
            video: ready == null
                ? video
                : video.copyWith(explicitMusicDownload: fingerprint),
            legacyDownload: ready == null,
          ));
        }
      }
    }
    final songs = [
      for (final track in tracks)
        if (!track.legacyDownload) track.video,
    ];
    final positions = {
      for (var i = 0; i < songs.length; i++) songs[i].videoId: i,
    };
    final likedById = {for (final song in liked) song.id: song};
    final playableDeviceCount = deviceSongs.map(_deviceEntry).nonNulls.length;
    final count = tracks.length + deviceSongs.length;
    final details = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          if (count == 0)
            Text(locals.musicEmptyCollection)
          else
            Text(locals.musicTrackCount(count)),
          if (songs.isNotEmpty)
            _playControls(locals,
                play: () => _playSongs(songs, title),
                shuffle: songs.length > 1
                    ? () => _playSongs(songs, title, shuffle: true)
                    : null),
        ],
      ),
    );
    final deviceById = {for (final song in deviceSongs) song.id: song};
    final selectable = {
      for (final track in tracks)
        track.video.videoId: track.legacyDownload ? null : track.video,
      for (final song in deviceSongs)
        if (_deviceEntry(song)?.deviceTrack case final track?)
          song.id: devicePlaylistVideo(track)
        else
          song.id: null,
    };
    List<OnDeviceMusicEntry>? resolveDeviceSongs(List<String> ids) {
      final resolved = [
        for (final id in ids)
          if (deviceById[id] case final song?)
            if (_deviceEntry(song) case final entry?) entry,
      ];
      return resolved.length == ids.length ? resolved : null;
    }

    return MusicDerivedSongSelection(
      key: ValueKey(widget.collection),
      songs: selectable,
      isCurrent: () => widget.session.isCurrent,
      deviceLibrary: _deviceLibrary,
      resolveOnDevice: resolveDeviceSongs,
      removal: _liked
          ? (label: locals.musicRemoveSelectedLikedSongs, run: _removeLikes)
          : null,
      builder: (context, selection) => MusicCollectionPanes(
        details: details,
        buildTracks: (_, split) => CustomScrollView(
          slivers: [
            if (!split) SliverToBoxAdapter(child: details),
            SliverList.builder(
              itemCount: tracks.length,
              itemBuilder: (context, index) {
                final track = tracks[index];
                final song = track.video;
                return _songRow(
                  song,
                  selection: selection,
                  play: track.legacyDownload
                      ? () => unawaited(_play(() => openHistoryEntry(
                          context, HistorySource.music, song,
                          television: isTv)))
                      : () => _playSongs(songs, title,
                          index: positions[song.videoId]!),
                  liked: likedById[song.videoId],
                );
              },
            ),
            if (deviceSongs.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _heading(locals.onDevice),
                    if (playableDeviceCount > 0)
                      Center(
                        child: _playControls(locals,
                            play: () => _playDevice(deviceSongs, title),
                            shuffle: playableDeviceCount > 1
                                ? () => _playDevice(deviceSongs, title,
                                    shuffle: true)
                                : null),
                      ),
                  ],
                ),
              ),
              SliverList.builder(
                itemCount: deviceSongs.length,
                itemBuilder: (context, index) {
                  final song = deviceSongs[index];
                  final device = _deviceEntry(song);
                  return ListTile(
                    key: ValueKey('music-automatic-track-${song.id}'),
                    leading: const Icon(Icons.audio_file_outlined),
                    title: Text(device?.title ?? song.title),
                    subtitle: Text(device == null
                        ? locals.localMusicHiddenFileUnavailable
                        : device.artist ?? song.subtitle),
                    selected: selection.selected(song.id) ?? false,
                    onTap: selection.active
                        ? () => selection.toggle(song.id)
                        : device == null
                            ? null
                            : () =>
                                _playDevice(deviceSongs, title, from: song.id),
                    onLongPress: () => selection.start(song.id),
                    trailing: _selectionActions(
                        selection, song.id, _liked ? song : null),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 6),
        child: Semantics(
          header: true,
          child: Text(text, style: Theme.of(context).textTheme.titleMedium),
        ),
      );

  Widget _playControls(AppLocalizations locals,
          {required VoidCallback play, VoidCallback? shuffle}) =>
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Wrap(
          spacing: 8,
          runSpacing: 6,
          alignment: WrapAlignment.center,
          children: [
            FilledButton.icon(
                onPressed: play,
                icon: const Icon(Icons.play_arrow),
                label: Text(locals.musicPlayAll)),
            if (shuffle != null)
              FilledButton.tonalIcon(
                  onPressed: shuffle,
                  icon: const Icon(Icons.shuffle),
                  label: Text(locals.musicShuffle)),
          ],
        ),
      );

  Widget _songRow(Video song,
      {required VoidCallback play,
      required MusicDerivedSongSelectionState selection,
      MusicLibraryEntry? liked}) {
    final music = song.musicMetadata;
    final artist = music?.artist ?? song.author ?? '';
    final images = displaySongThumbnails(
        song.videoId, music?.thumbnails ?? const [], song.videoThumbnails,
        artTrack: music?.isArtTrack == true);
    return ListTile(
      key: ValueKey('music-automatic-track-${song.videoId}'),
      selected: selection.selected(song.videoId) ?? false,
      onTap: selection.active ? () => selection.toggle(song.videoId) : play,
      onLongPress: () => selection.start(song.videoId),
      leading: ExcludeSemantics(
        child: SizedBox.square(
          dimension: 48,
          child: images.isEmpty
              ? const Icon(Icons.music_note)
              : Thumbnail(
                  musicArtwork: true,
                  images: images,
                  instanceOnly: true,
                  decoration:
                      BoxDecoration(borderRadius: BorderRadius.circular(6)),
                  fallback: const Icon(Icons.music_note),
                ),
        ),
      ),
      title: Text(music?.title ?? song.title ?? song.videoId,
          maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: artist.isEmpty
          ? null
          : Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: _selectionActions(selection, song.videoId, liked),
    );
  }

  Widget _selectionActions(MusicDerivedSongSelectionState selection, String id,
      MusicLibraryEntry? liked) {
    final button = MusicSongSelectButton(
      selected: selection.selected(id),
      onPressed: () => selection.toggle(id),
    );
    if (liked == null || selection.active) return button;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [button, _unlikeButton(AppLocalizations.of(context)!, liked)],
    );
  }

  Widget _unlikeButton(AppLocalizations locals, MusicLibraryEntry song) =>
      IconButton(
        key: ValueKey('music-automatic-unlike-${song.id}'),
        tooltip: locals.musicUnlikeSong,
        icon: const Icon(Icons.favorite),
        onPressed: () => unawaited(_unlike(song)),
      );
}
