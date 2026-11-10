import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/music_album.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_page.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_playlist.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/components/music_playlist_resume.dart';
import 'package:clipious/music/views/components/music_sponsor_notice.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/backend_recovery_notice.dart';
import 'package:clipious/player/views/components/playlist_loading_notice.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/utils/views/tv/components/tv_overscan.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/offline_video_thumbnail.dart';
import 'package:clipious/videos/views/components/video_watch_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

enum _MusicSearch { songs, albums, artists, playlists }

@RoutePage()
class MusicScreen extends StatefulWidget {
  final String? videoId;
  final String? albumId;
  final String? playlistId;
  final String? artistId;

  const MusicScreen(
      {super.key, this.videoId, this.albumId, this.playlistId, this.artistId});

  static Widget tvAudio({Video? video, DownloadedVideo? offlineVideo}) =>
      _MusicTvAudio(video: video, offlineVideo: offlineVideo);

  static Future<void> playTracks(BuildContext context, List<Video> videos,
      {PlaylistReference? reference,
      int startIndex = 0,
      Duration startAt = Duration.zero}) async {
    if (videos.isEmpty) return;
    if (reference != null && reference.profileId != db.profileId) return;
    if (isTv) {
      await Navigator.of(context).push<void>(MaterialPageRoute(
          builder: (_) => _MusicTvPlayer(
              videos: videos,
              reference: reference,
              startIndex: startIndex,
              startAt: startAt)));
    } else if (reference != null) {
      await context.read<PlayerCubit>().playPlaylist(videos,
          reference: reference,
          startIndex: startIndex,
          audio: true,
          startAt: startAt);
    } else {
      await context
          .read<PlayerCubit>()
          .playVideo(videos, audio: true, startAt: startAt);
    }
  }

  @override
  State<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends State<MusicScreen> {
  final _search = TextEditingController();
  _MusicSearch _type = _MusicSearch.songs;
  List<MusicTrack> _songs = [];
  List<MusicAlbum> _albums = [];
  List<MusicArtist> _artists = [];
  List<MusicPlaylist> _playlists = [];
  MusicCollection? _collection;
  bool _collectionIsAlbum = true;
  MusicArtistPage? _artistPage;
  final _browseHistory =
      <({MusicCollection? collection, MusicArtistPage? artist, bool album})>[];
  bool _loading = false;
  Object? _failure;
  bool _searched = false;
  bool _starting = false;
  int _generation = 0;
  Future<void> Function()? _retry;

  bool get _hasBrowsePage => _collection != null || _artistPage != null;

  // A direct catalog link has no search results to return to. Preserve in-page
  // history first; submitting a search establishes a new local destination.
  bool get _returnToOrigin =>
      _hasBrowsePage &&
      !_searched &&
      _browseHistory.isEmpty &&
      (widget.albumId != null ||
          widget.artistId != null ||
          widget.playlistId != null);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openInitial();
    });
  }

  @override
  void didUpdateWidget(MusicScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoId != widget.videoId ||
        oldWidget.albumId != widget.albumId ||
        oldWidget.playlistId != widget.playlistId ||
        oldWidget.artistId != widget.artistId) {
      _openInitial();
    }
  }

  @override
  void dispose() {
    _generation++;
    _search.dispose();
    super.dispose();
  }

  bool _sameSession(AppState initial) {
    if (!mounted) return false;
    final current = context.read<AppCubit>().state;
    return !current.globalLoading &&
        !current.sessionRecoveryRequired &&
        current.profileId == initial.profileId &&
        current.sessionRevision == initial.sessionRevision &&
        current.server == initial.server;
  }

  bool _active(int generation, AppState initial) =>
      mounted && generation == _generation && _sameSession(initial);

  void _clearForSession() {
    _generation++;
    setState(() {
      _loading = false;
      _failure = null;
      _searched = false;
      _starting = false;
      _songs = [];
      _albums = [];
      _artists = [];
      _playlists = [];
      _collection = null;
      _artistPage = null;
      _browseHistory.clear();
      _retry = null;
    });
  }

  Future<void> _openInitial() async {
    if (widget.albumId != null) {
      await _openCollection(widget.albumId!, album: true);
    } else if (widget.playlistId != null) {
      await _openCollection(widget.playlistId!, album: false);
    } else if (widget.videoId != null) {
      await _openSong(widget.videoId!);
    } else if (widget.artistId != null) {
      await _openArtist(widget.artistId!);
    }
  }

  Future<void> _run(Future<void> Function(int, AppState) operation,
      Future<void> Function() retry) async {
    final session = context.read<AppCubit>().state;
    if (!_sameSession(session)) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failure = null;
      _retry = retry;
    });
    try {
      await operation(generation, session);
    } catch (error) {
      if (_active(generation, session)) {
        setState(() => _failure = error);
      }
    } finally {
      if (_active(generation, session)) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    final query = _search.text.trim();
    if (query.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final type = _type;
    setState(() {
      _searched = true;
      _collection = null;
      _artistPage = null;
      _browseHistory.clear();
      _songs = [];
      _albums = [];
      _artists = [];
      _playlists = [];
    });
    await _run((generation, session) async {
      if (type == _MusicSearch.songs) {
        final songs = await musicCatalogService.searchSongs(query);
        if (_active(generation, session)) setState(() => _songs = songs);
      } else if (type == _MusicSearch.albums) {
        final albums = await musicCatalogService.searchAlbums(query);
        if (_active(generation, session)) setState(() => _albums = albums);
      } else if (type == _MusicSearch.artists) {
        final artists = await musicCatalogService.searchArtists(query);
        if (_active(generation, session)) setState(() => _artists = artists);
      } else {
        final playlists = await musicCatalogService.searchPlaylists(query);
        if (_active(generation, session)) {
          setState(() => _playlists = playlists);
        }
      }
    }, _submit);
  }

  Future<void> _openCollection(String id, {required bool album}) async {
    await _run((generation, session) async {
      final collection = album
          ? await musicCatalogService.getAlbum(id)
          : await musicCatalogService.getPlaylist(id);
      if (_active(generation, session)) {
        setState(() {
          _rememberBrowsePage();
          _collection = collection;
          _collectionIsAlbum = album;
          _artistPage = null;
        });
      }
    }, () => _openCollection(id, album: album));
  }

  void _rememberBrowsePage() {
    if (_collection != null || _artistPage != null) {
      _browseHistory.add((
        collection: _collection,
        artist: _artistPage,
        album: _collectionIsAlbum
      ));
    }
  }

  Future<void> _openArtist(String id) async {
    if (!_loading && _artistPage?.artist.id == id) return;
    await _run((generation, session) async {
      final artist = await musicCatalogService.getArtist(id);
      if (_active(generation, session)) {
        setState(() {
          _rememberBrowsePage();
          _artistPage = artist;
          _collection = null;
        });
      }
    }, () => _openArtist(id));
  }

  Future<void> _openSong(String id) async {
    await _run((generation, session) async {
      final song = await musicCatalogService.getSong(id);
      if (!_active(generation, session)) return;
      setState(() {
        _songs = [song];
        _type = _MusicSearch.songs;
        _searched = true;
        _collection = null;
        _artistPage = null;
        _browseHistory.clear();
      });
      await _play([song]);
    }, () => _openSong(id));
  }

  Future<void> _play(List<MusicTrack> tracks,
      {PlaylistReference? reference,
      int startIndex = 0,
      Duration startAt = Duration.zero}) async {
    final session = context.read<AppCubit>().state;
    if (_starting || tracks.isEmpty || !_sameSession(session)) return;
    final videos = tracks.map((track) => track.toVideo()).toList();
    setState(() => _starting = true);
    try {
      await MusicScreen.playTracks(context, videos,
          reference: reference, startIndex: startIndex, startAt: startAt);
    } catch (_) {
      if (!mounted) return;
      if (_sameSession(session)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.musicPlaybackError)));
      }
    } finally {
      if (_sameSession(session)) setState(() => _starting = false);
    }
  }

  void _backToSearch() {
    _generation++;
    setState(() {
      if (_browseHistory.isNotEmpty) {
        final previous = _browseHistory.removeLast();
        _collection = previous.collection;
        _artistPage = previous.artist;
        _collectionIsAlbum = previous.album;
      } else {
        _collection = null;
        _artistPage = null;
      }
      _loading = false;
      _failure = null;
      _retry = null;
    });
  }

  Future<void> _resumeListening() async {
    final session = context.read<AppCubit>().state;
    if (_starting || !_sameSession(session)) return;
    final player = context.read<PlayerCubit>();
    final saved = player.savedSession;
    if (saved == null) return;
    setState(() => _starting = true);
    try {
      if (isTv) {
        await Navigator.of(context).push<void>(MaterialPageRoute(
            builder: (_) =>
                _MusicTvPlayer(videos: saved.videos, resumeSession: true)));
      } else {
        await player.resumeSession();
      }
    } catch (_) {
      if (!mounted) return;
      if (_sameSession(session)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.musicPlaybackError)));
      }
    } finally {
      if (_sameSession(session)) setState(() => _starting = false);
    }
  }

  Widget _resumeAction() =>
      BlocBuilder<PlayerCubit, PlayerState>(builder: (context, state) {
        final player = context.read<PlayerCubit>();
        final locals = AppLocalizations.of(context)!;
        final activeMusic = !state.isHidden &&
            state.isAudio &&
            (state.currentlyPlaying?.musicMetadata != null ||
                state.offlineCurrentlyPlaying?.musicMetadata != null);
        if (activeMusic && !isTv) {
          return TextButton.icon(
              key: const ValueKey('music-now-playing'),
              onPressed: player.showBigPlayer,
              icon: const Icon(Icons.graphic_eq),
              label: Text(locals.musicNowPlaying));
        }
        final saved = player.savedSession;
        final savedOffline =
            saved == null ? null : db.getDownloadByVideoId(saved.currentId);
        final savedMusic = saved != null &&
            saved.audio &&
            (saved.videos.any((video) =>
                    playbackQueueId(video) == saved.currentId &&
                    video.musicMetadata != null) ||
                (saved.offlineIds.contains(saved.currentId) &&
                    savedOffline?.downloadComplete == true &&
                    savedOffline?.musicMetadata != null));
        if (!savedMusic || (!state.isHidden && state.hasVideo)) {
          return const SizedBox.shrink();
        }
        return TextButton.icon(
            key: const ValueKey('music-resume'),
            onPressed: _starting ? null : _resumeListening,
            icon: const Icon(Icons.play_arrow),
            label: Text(locals.musicResume));
      });

  Widget _artwork(List<ImageObject> images) => SizedBox.square(
      dimension: 56,
      child: images.isEmpty
          ? const Icon(Icons.music_note)
          : Thumbnail(
              images: images,
              useInvidiousProxy: false,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
            ));

  Widget _artistByline(List<String> names, List<MusicArtist> links) {
    if (links.isEmpty) {
      return Text(names.join(', '),
          maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    final labels = names.isEmpty ? links.map((artist) => artist.name) : names;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        for (final name in labels)
          if (links.where((artist) => artist.name == name).firstOrNull
              case final artist?)
            TextButton(
                style: TextButton.styleFrom(
                    padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
                onPressed: () => _openArtist(artist.id),
                child: Text(name))
          else
            Text(name),
      ],
    );
  }

  Widget _albumTile(MusicAlbum album) => ListTile(
      leading: _artwork(album.thumbnails),
      title: Text(album.title),
      subtitle: _artistByline(album.artists, album.artistLinks),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _openCollection(album.id, album: true));

  Widget _song(MusicTrack track,
      {int? index, List<MusicTrack>? queue, PlaylistReference? reference}) {
    return ListTile(
      key: ValueKey('music-song-${index ?? 'search'}-${track.videoId}'),
      leading: index == null
          ? _artwork(track.thumbnails)
          : SizedBox.square(
              dimension: 36,
              child: Stack(fit: StackFit.expand, children: [
                Center(child: Text('${index + 1}')),
                VideoWatchProgress(videoId: track.videoId),
              ])),
      title: Text(track.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _artistByline(track.artists, track.artistLinks),
          if (index == null &&
              track.albumId != null &&
              track.albumTitle != null)
            TextButton(
                style: TextButton.styleFrom(
                    padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
                onPressed: () => _openCollection(track.albumId!, album: true),
                child: Text(track.albumTitle!,
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
      ),
      trailing: MusicLibraryActions(videos: [track.toVideo()]),
      onTap: _starting
          ? null
          : () => reference != null && queue != null && index != null
              ? _play(queue, reference: reference, startIndex: index)
              : _play(index == null || queue == null
                  ? [track]
                  : queue.skip(index).toList()),
    );
  }

  Widget _results() {
    final locals = AppLocalizations.of(context)!;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_failure != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
                _failure is MusicCatalogRegionUnavailable
                    ? locals.musicRegionUnavailable
                    : locals.musicCatalogError,
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.refresh),
                label: Text(locals.retry)),
          ]),
        ),
      );
    }
    final collection = _collection;
    if (collection != null) return _collectionResults(collection);
    final artistPage = _artistPage;
    if (artistPage != null) return _artistResults(artistPage);
    if (!_searched) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(locals.musicSearchStart, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(locals.musicCatalogConnection,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      );
    }
    if (_type == _MusicSearch.songs) {
      if (_songs.isEmpty) return Center(child: Text(locals.musicNoResults));
      return ListView.builder(
          itemCount: _songs.length,
          itemBuilder: (_, index) => _song(_songs[index]));
    }
    if (_type == _MusicSearch.albums) {
      if (_albums.isEmpty) return Center(child: Text(locals.musicNoResults));
      return ListView.builder(
          itemCount: _albums.length,
          itemBuilder: (_, index) => _albumTile(_albums[index]));
    }
    if (_type == _MusicSearch.artists) {
      if (_artists.isEmpty) return Center(child: Text(locals.musicNoResults));
      return ListView.builder(
          itemCount: _artists.length,
          itemBuilder: (_, index) {
            final artist = _artists[index];
            return ListTile(
                leading: _artwork(artist.thumbnails),
                title: Text(artist.name),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openArtist(artist.id));
          });
    }
    if (_playlists.isEmpty) return Center(child: Text(locals.musicNoResults));
    return ListView.builder(
        itemCount: _playlists.length,
        itemBuilder: (_, index) {
          final playlist = _playlists[index];
          return ListTile(
              leading: _artwork(playlist.thumbnails),
              title: Text(playlist.title),
              subtitle: playlist.author == null ? null : Text(playlist.author!),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openCollection(playlist.id, album: false));
        });
  }

  Widget _collectionResults(MusicCollection collection) {
    final locals = AppLocalizations.of(context)!;
    final reference = _collectionIsAlbum
        ? null
        : PlaylistReference(
            kind: PlaylistSourceKind.public,
            playlistId: collection.id,
            profileId: db.profileId);
    return ListView(children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _artwork(collection.thumbnails),
          const SizedBox(height: 12),
          Text(collection.title, style: Theme.of(context).textTheme.titleLarge),
          _artistByline(collection.artists, collection.artistLinks),
          const SizedBox(height: 12),
          FilledButton.icon(
              key: const ValueKey('music-play-all'),
              onPressed: _starting || collection.tracks.isEmpty
                  ? null
                  : () => _play(collection.tracks, reference: reference),
              icon: const Icon(Icons.play_arrow),
              label: Text(locals.musicPlayAll)),
          if (reference != null)
            MusicPlaylistResume(
                reference: reference,
                videos:
                    collection.tracks.map((track) => track.toVideo()).toList(),
                enabled: !_starting,
                onPlay: (index, position) => _play(collection.tracks,
                    reference: reference,
                    startIndex: index,
                    startAt: position)),
          const SizedBox(height: 8),
          MusicBookmarkButton(
              entry: MusicLibraryEntry.collection(collection,
                  album: _collectionIsAlbum)),
          MusicLibraryActions(
              videos:
                  collection.tracks.map((track) => track.toVideo()).toList(),
              compact: false),
        ]),
      ),
      if (collection.tracks.isEmpty)
        Padding(
            padding: const EdgeInsets.all(24),
            child: Text(locals.musicEmptyCollection)),
      for (var i = 0; i < collection.tracks.length; i++)
        _song(collection.tracks[i],
            index: i, queue: collection.tracks, reference: reference),
    ]);
  }

  Widget _artistResults(MusicArtistPage artistPage) {
    final locals = AppLocalizations.of(context)!;
    return ListView(children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _artwork(artistPage.artist.thumbnails),
          const SizedBox(height: 12),
          Text(artistPage.artist.name,
              style: Theme.of(context).textTheme.titleLarge),
          MusicBookmarkButton(
              entry: MusicLibraryEntry.artist(artistPage.artist)),
          if (artistPage.description case final String description)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(description,
                  maxLines: 6, overflow: TextOverflow.ellipsis),
            ),
        ]),
      ),
      if (artistPage.songs.isNotEmpty) ...[
        _sectionTitle(locals.musicArtistSongs),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
                key: const ValueKey('music-play-artist-songs'),
                onPressed: _starting ? null : () => _play(artistPage.songs),
                icon: const Icon(Icons.play_arrow),
                label: Text(locals.musicPlayAll)),
          ),
        ),
        for (var i = 0; i < artistPage.songs.length; i++)
          _song(artistPage.songs[i], index: i, queue: artistPage.songs),
      ],
      if (artistPage.albums.isNotEmpty) ...[
        _sectionTitle(locals.musicArtistAlbums),
        for (final album in artistPage.albums) _albumTile(album),
      ],
      if (artistPage.singles.isNotEmpty) ...[
        _sectionTitle(locals.musicArtistSingles),
        for (final single in artistPage.singles) _albumTile(single),
      ],
      if (artistPage.songs.isEmpty &&
          artistPage.albums.isEmpty &&
          artistPage.singles.isEmpty)
        Padding(
            padding: const EdgeInsets.all(24),
            child: Text(locals.musicArtistEmpty)),
    ]);
  }

  Widget _sectionTitle(String title) => Padding(
      padding: const EdgeInsets.all(16),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium));

  String _searchLabel(_MusicSearch search, AppLocalizations locals) =>
      switch (search) {
        _MusicSearch.songs => locals.musicSongs,
        _MusicSearch.albums => locals.musicAlbums,
        _MusicSearch.artists => locals.musicArtists,
        _MusicSearch.playlists => locals.musicPlaylists,
      };

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return BlocListener<AppCubit, AppState>(
      listenWhen: (before, after) =>
          before.profileId != after.profileId ||
          before.sessionRevision != after.sessionRevision ||
          before.server != after.server ||
          (!before.globalLoading && after.globalLoading) ||
          (!before.sessionRecoveryRequired && after.sessionRecoveryRequired),
      listener: (context, state) => _clearForSession(),
      child: PopScope(
        canPop: !_hasBrowsePage || _returnToOrigin,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && !_returnToOrigin) _backToSearch();
        },
        child: Shortcuts(
          shortcuts: {
            LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(locals.music),
              leading: !_hasBrowsePage
                  ? null
                  : IconButton(
                      tooltip: _browseHistory.isEmpty && !_returnToOrigin
                          ? locals.musicBackToSearch
                          : MaterialLocalizations.of(context).backButtonTooltip,
                      onPressed: () {
                        if (_returnToOrigin) {
                          Navigator.of(context).maybePop();
                        } else {
                          _backToSearch();
                        }
                      },
                      icon: const Icon(Icons.arrow_back)),
            ),
            body: SafeArea(
              child: Padding(
                padding: isTv
                    ? EdgeInsets.symmetric(
                        horizontal: TvOverscan.horizontal,
                        vertical: TvOverscan.vertical)
                    : EdgeInsets.zero,
                child: Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: TextField(
                      key: const ValueKey('music-search'),
                      controller: _search,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                          labelText: locals.musicSearchHint,
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                              autofocus: isTv,
                              tooltip: locals.search,
                              onPressed: _submit,
                              icon: const Icon(Icons.search))),
                    ),
                  ),
                  if (isTv)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: _resumeAction()),
                    )
                  else
                    _resumeAction(),
                  if (!_hasBrowsePage)
                    SingleChildScrollView(
                      key: const ValueKey('music-search-filters'),
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(children: [
                        for (final type in _MusicSearch.values)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                                label: Text(_searchLabel(type, locals)),
                                selected: _type == type,
                                onSelected: (_) {
                                  if (_type == type) return;
                                  setState(() => _type = type);
                                  if (_search.text.trim().isNotEmpty) _submit();
                                }),
                          ),
                      ]),
                    ),
                  const SizedBox(height: 8),
                  Expanded(child: _results()),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// TV routes own their player, as the TV home does not mount the phone player.
class _MusicTvPlayer extends StatelessWidget {
  final List<Video> videos;
  final bool resumeSession;
  final PlaylistReference? reference;
  final int startIndex;
  final Duration startAt;

  const _MusicTvPlayer(
      {required this.videos,
      this.resumeSession = false,
      this.reference,
      this.startIndex = 0,
      this.startAt = Duration.zero});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => PlayerCubit(
          PlayerState.init(resumeSession ? null : videos).copyWith(
              isAudio: true, isMini: false, isHidden: false, startAt: startAt),
          context.read<SettingsCubit>(),
          resume: resumeSession,
          playlistReference: reference,
          startIndex: startIndex,
          playlistAudio: true),
      child: Shortcuts(
        shortcuts: {
          LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
        },
        child: Scaffold(
          appBar: AppBar(title: Text(AppLocalizations.of(context)!.music)),
          body: SafeArea(
            child: BlocBuilder<PlayerCubit, PlayerState>(
              builder: (context, state) {
                final player = context.read<PlayerCubit>();
                if (state.isClosing ||
                    (state.videos.isEmpty && state.offlineVideos.isEmpty)) {
                  return _MusicPlaybackFailure(
                      onRetry: resumeSession
                          ? player.resumeSession
                          : () => reference == null
                              ? player.playVideo(videos,
                                  audio: true, startAt: startAt)
                              : player.playPlaylist(videos,
                                  reference: reference!,
                                  startIndex: startIndex,
                                  audio: true,
                                  startAt: startAt));
                }
                if (state.currentlyPlaying == null &&
                    state.offlineCurrentlyPlaying == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                return _MusicTvAudio(
                    video: state.currentlyPlaying,
                    offlineVideo: state.offlineCurrentlyPlaying);
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _MusicPlaybackFailure extends StatelessWidget {
  final VoidCallback onRetry;

  const _MusicPlaybackFailure({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(locals.musicPlaybackError, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        FilledButton.icon(
            autofocus: true,
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(locals.retry)),
      ]),
    );
  }
}

/// Keep transport buttons visible and focusable while using the shared decoder.
class _MusicTvAudio extends StatelessWidget {
  final Video? video;
  final DownloadedVideo? offlineVideo;

  const _MusicTvAudio({this.video, this.offlineVideo});

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerCubit>();
    final locals = AppLocalizations.of(context)!;
    return BlocProvider(
      create: (_) => AudioPlayerCubit(
          AudioPlayerState(video: video, offlineVideo: offlineVideo),
          player,
          context.read<SettingsCubit>()),
      child: BlocListener<PlayerCubit, PlayerState>(
        listenWhen: (before, after) =>
            before.mediaCommand != after.mediaCommand &&
            after.mediaCommand != null,
        listener: (context, state) =>
            context.read<AudioPlayerCubit>().handleCommand(state.mediaCommand!),
        child: BlocBuilder<AudioPlayerCubit, AudioPlayerState>(
          builder: (context, audio) {
            final state = context.watch<PlayerCubit>().state;
            final current = state.currentlyPlaying ?? video;
            final offline = state.offlineCurrentlyPlaying ?? offlineVideo;
            final metadata = current?.musicMetadata ?? offline?.musicMetadata;
            final musicImages = metadata?.thumbnails ?? const <ImageObject>[];
            if (audio.error != null ||
                state.mediaEvent.state == MediaState.error) {
              return _MusicPlaybackFailure(
                  onRetry: current == null
                      ? player.resumeSession
                      : () => player.switchToVideo(current,
                          startAt: state.position));
            }
            return Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: TvOverscan.horizontal,
                  vertical: TvOverscan.vertical),
              child: Column(children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: offline != null
                          ? OfflineVideoThumbnail(
                              borderRadius: 16, video: offline)
                          : Thumbnail(
                              images: musicImages.isNotEmpty
                                  ? musicImages
                                  : current?.videoThumbnails,
                              useInvidiousProxy: musicImages.isEmpty,
                              decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(16))),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(metadata?.title ?? current?.title ?? offline?.title ?? '',
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge),
                Text(
                    metadata?.artist ??
                        current?.author ??
                        offline?.author ??
                        '',
                    maxLines: 1),
                if (metadata?.album case final String album)
                  Text(album, maxLines: 1),
                const MusicSponsorNotice(),
                if (audio.loading) const LinearProgressIndicator(),
                if (state.backendRecovery case final recovery?)
                  BackendRecoveryNotice(recovery: recovery, compact: true),
                const PlaylistLoadingNotice(),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  IconButton(
                      tooltip: locals.musicPrevious,
                      onPressed: state.hasQueue ? player.playPrevious : null,
                      icon: const Icon(Icons.skip_previous)),
                  IconButton(
                      tooltip: locals.musicRewind,
                      onPressed: player.rewind,
                      icon: const Icon(Icons.fast_rewind)),
                  IconButton.filled(
                      autofocus: true,
                      tooltip: state.isPlaying
                          ? locals.musicPause
                          : locals.musicPlay,
                      onPressed: player.togglePlaying,
                      icon: Icon(
                          state.isPlaying ? Icons.pause : Icons.play_arrow)),
                  IconButton(
                      tooltip: locals.musicForward,
                      onPressed: player.fastForward,
                      icon: const Icon(Icons.fast_forward)),
                  IconButton(
                      tooltip: locals.musicNext,
                      onPressed: state.hasQueue ? player.playNext : null,
                      icon: const Icon(Icons.skip_next)),
                ]),
              ]),
            );
          },
        ),
      ),
    );
  }
}
