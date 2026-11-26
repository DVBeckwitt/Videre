import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:videre_proxy/videre_proxy.dart';

import '../../../app/states/app.dart';
import '../../../downloads/models/downloaded_video.dart';
import '../../../downloads/services/download_storage.dart';
import '../../../downloads/states/download_manager.dart';
import '../../../globals.dart' show db;
import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../player/states/player.dart';
import '../../../utils.dart' show prettyDurationCustom;
import '../../../utils/views/tv/components/tv_overscan.dart';
import '../../models/on_device_music_entry.dart';
import '../../services/cached_music.dart';
import '../components/cached_music_library.dart';
import 'music.dart';

class OfflineMusicPage extends StatefulWidget {
  const OfflineMusicPage({super.key});

  @override
  State<OfflineMusicPage> createState() => _OfflineMusicPageState();
}

class _OfflineMusicPageState extends State<OfflineMusicPage> {
  bool _showCache = false;

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final state = context.watch<AppCubit>().state;
    final cacheSupported = PlaybackCache.supported;
    final showCache = cacheSupported && _showCache;
    final session = (state.profileId, state.sessionRevision);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (cacheSupported)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: Text(locals.downloads),
                  autofocus: isTv,
                  selected: !showCache,
                  onSelected: (_) => setState(() => _showCache = false),
                ),
                ChoiceChip(
                  label: Text(locals.musicCachedSongs),
                  selected: showCache,
                  onSelected: (_) => setState(() => _showCache = true),
                ),
              ],
            ),
          ),
        Expanded(
          child: switch (state) {
            _
                when state.globalLoading ||
                    state.sessionRecoveryRequired ||
                    state.profileId != db.profileId =>
              const Center(child: CircularProgressIndicator()),
            AppState(:final server) when showCache => CachedMusicLibrary(
                key: ValueKey((db, session, server?.accountId)),
                active: TickerMode.of(context),
                server: server,
                onPlay: isTv
                    ? (songs,
                        {required startIndex,
                        required server,
                        required queueTitle}) async {
                        final owner = cachedMusicOwner(server);
                        if (owner == null) return;
                        await MusicScreen.playTracks(
                          context,
                          [for (final song in songs) song.playbackEntry(owner)],
                          startIndex: startIndex,
                          queueTitle: queueTitle,
                        );
                      }
                    : null,
              ),
            _ => _DownloadCollection(
                key: ValueKey((db, session)),
                profileId: state.profileId,
              ),
          },
        ),
      ],
    );
    final page = Scaffold(
      appBar: AppBar(title: Text(locals.musicOfflineTitle)),
      body: SafeArea(child: isTv ? TvOverscan(child: body) : body),
    );
    if (!isTv) return page;
    return Shortcuts(
      shortcuts: {
        const SingleActivator(LogicalKeyboardKey.select):
            const ActivateIntent(),
      },
      child: page,
    );
  }
}

class _DownloadCollection extends StatelessWidget {
  const _DownloadCollection({super.key, required this.profileId});

  final String profileId;

  @override
  Widget build(BuildContext context) {
    final manager = context.read<DownloadManagerCubit?>();
    if (manager == null) {
      return Center(
          child: Text(AppLocalizations.of(context)!.musicEmptyCollection));
    }
    return BlocSelector<DownloadManagerCubit, DownloadManagerState,
        List<DownloadedVideo>>(
      bloc: manager,
      selector: (state) => state.videos,
      builder: (context, downloads) => _VerifiedDownloads(
        key: ObjectKey(manager),
        manager: manager,
        profileId: profileId,
        downloads: downloads,
      ),
    );
  }
}

class _VerifiedDownloads extends StatefulWidget {
  const _VerifiedDownloads({
    super.key,
    required this.manager,
    required this.profileId,
    required this.downloads,
  });

  final DownloadManagerCubit manager;
  final String profileId;
  final List<DownloadedVideo> downloads;

  @override
  State<_VerifiedDownloads> createState() => _VerifiedDownloadsState();
}

class _VerifiedDownloadsState extends State<_VerifiedDownloads> {
  late Future<List<MusicFileProbe>> _files;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _files = _probe(widget.downloads);
  }

  @override
  void didUpdateWidget(_VerifiedDownloads oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(widget.downloads, oldWidget.downloads)) {
      _files = _probe(widget.downloads);
    }
  }

  Future<List<MusicFileProbe>> _probe(List<DownloadedVideo> downloads) =>
      widget.manager.storage.probeMusicFiles(widget.profileId, downloads);

  Future<void> _open(MusicFileProbe selected) async {
    if (_opening) return;
    final app = context.read<AppCubit>();
    final appState = app.state;
    final player = context.read<PlayerCubit?>();
    final manager = widget.manager;
    final database = db;
    final profileId = widget.profileId;
    final route = ModalRoute.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final locals = AppLocalizations.of(context)!;
    var openingTvPlayer = false;
    bool current() {
      final state = app.state;
      return mounted &&
          !app.isClosed &&
          !manager.isClosed &&
          (openingTvPlayer
              ? route?.isActive != false
              : route?.isCurrent != false) &&
          identical(db, database) &&
          database.profileId == profileId &&
          state.profileId == profileId &&
          state.sessionRevision == appState.sessionRevision &&
          state.server == appState.server &&
          !state.globalLoading &&
          !state.sessionRecoveryRequired;
    }

    if (player == null || player.isClosed || !current()) return;
    setState(() => _opening = true);
    try {
      final downloads = manager.state.videos;
      final checked = await _probe(downloads);
      if (!mounted || !current() || player.isClosed) return;

      final present = manager.state.videos.toSet();
      final ready = [
        for (final file in checked)
          if (present.contains(file.download)) file,
      ];
      if (listEquals(downloads, manager.state.videos)) {
        setState(() {
          _files = Future.value(ready);
        });
      }
      final index = ready.indexWhere((file) =>
          file.download == selected.download &&
          file.identity == selected.identity);
      if (index < 0) return;
      openingTvPlayer = isTv;
      await MusicScreen.playOnDeviceTracks(
        context,
        [
          for (final file in ready)
            OnDeviceMusicEntry.download(
              file.download,
              file.identity,
              sizeBytes: file.byteLength,
            ),
        ],
        startIndex: index,
        queueTitle: locals.downloads,
        isCurrent: () =>
            _opening &&
            current() &&
            manager.state.videos.contains(selected.download),
      );
    } catch (_) {
      if (current() && messenger?.mounted == true) {
        messenger!
            .showSnackBar(SnackBar(content: Text(locals.musicPlaybackError)));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return FutureBuilder(
      future: _files,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final files = snapshot.data ?? const <MusicFileProbe>[];
        if (files.isEmpty) {
          return Center(child: Text(locals.musicEmptyCollection));
        }
        return ListView.builder(
          itemCount: files.length,
          itemBuilder: (context, index) {
            final file = files[index];
            final song = file.download.musicMetadata!;
            final seconds = file.download.lengthSeconds;
            return ListTile(
              key: ValueKey(file.download.videoId),
              leading: const Icon(Icons.music_note),
              title: Text(song.title),
              subtitle: song.artist.isEmpty ? null : Text(song.artist),
              trailing: seconds > 0
                  ? Text(prettyDurationCustom(Duration(seconds: seconds)))
                  : null,
              onTap: _opening ? null : () => unawaited(_open(file)),
            );
          },
        );
      },
    );
  }
}
