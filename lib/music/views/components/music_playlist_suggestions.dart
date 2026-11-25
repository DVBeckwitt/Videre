import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// A manually requested catalog shelf, scoped to an open local playlist.
class MusicPlaylistSuggestions extends StatefulWidget {
  final Playlist playlist;
  final String profileId;
  final bool visible;

  const MusicPlaylistSuggestions({
    super.key,
    required this.playlist,
    required this.profileId,
    required this.visible,
  });

  static final _onlineId = RegExp(r'^[A-Za-z0-9_-]{11}$');

  static Iterable<String> _seedIds(Playlist playlist) sync* {
    for (final video in playlist.videos) {
      if (video.musicMetadata != null && _onlineId.hasMatch(video.videoId)) {
        yield video.videoId;
      }
    }
  }

  static bool hasSeeds(Playlist playlist) => _seedIds(playlist).isNotEmpty;

  @override
  State<MusicPlaylistSuggestions> createState() =>
      _MusicPlaylistSuggestionsState();
}

class _MusicPlaylistSuggestionsState extends State<MusicPlaylistSuggestions> {
  final _hidden = <String>{};
  final _saving = <String>{};
  List<MusicTrack>? _candidates;
  bool _loading = false;
  bool _loadFailed = false;
  late ValueListenable<bool> _tickerMode;
  ModalRoute<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerMode = TickerMode.getNotifier(context);
    _route = ModalRoute.of(context);
  }

  RecommendationService get _recommendations =>
      RecommendationService.forProfile(db, widget.profileId);

  bool _isActive(MusicLibrarySession session) =>
      mounted &&
      widget.visible &&
      session.isCurrent &&
      session.library.profileId == widget.profileId &&
      _tickerMode.value &&
      (_route?.isCurrent ?? true);

  bool _canEdit(MusicLibrarySession session) =>
      _isActive(session) &&
      session.playlists.any((playlist) =>
          playlist.playlistId == widget.playlist.playlistId &&
          !playlist.isEditLocked);

  Future<void> _find() async {
    if (!mounted || _loading) return;
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!_canEdit(session)) return;
    final seeds = MusicPlaylistSuggestions._seedIds(widget.playlist)
        .toSet()
        .take(3)
        .toList();
    final catalog = musicCatalogService;
    bool current() =>
        _isActive(session) && identical(musicCatalogService, catalog);

    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final tracks = await catalog.getRelatedSongs(seeds, isCurrent: current);
      if (current() && _canEdit(session)) setState(() => _candidates = tracks);
    } catch (_) {
      if (current()) setState(() => _loadFailed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add(MusicTrack track) async {
    if (!mounted) return;
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!_canEdit(session) ||
        _hidden.contains(track.videoId) ||
        _recommendations.eligibleMusic([track]).isEmpty ||
        !_saving.add(track.videoId)) {
      return;
    }
    setState(() {});
    try {
      await service.appendLocalPlaylistEntries(
        widget.playlist.playlistId,
        [track.toVideo()],
        allowDuplicates: false,
        database: db.forProfile(widget.profileId),
        isCurrent: () => _isActive(session),
      );
      if (session.isCurrent) session.library.notifyChanged();
    } catch (_) {
      if (mounted && _isActive(session)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              AppLocalizations.of(context)!.musicPlaylistSuggestionAddFailed),
        ));
      }
    } finally {
      if (mounted) setState(() => _saving.remove(track.videoId));
    }
  }

  void _dismiss(MusicTrack track) {
    if (!mounted || _saving.contains(track.videoId)) return;
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (_canEdit(session)) setState(() => _hidden.add(track.videoId));
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();
    final locals = AppLocalizations.of(context)!;
    final excluded = {
      for (final video in widget.playlist.videos) video.videoId,
      ..._hidden,
    };
    final tracks = _candidates == null
        ? const <MusicTrack>[]
        : _recommendations
            .eligibleMusic(_candidates!
                .where((track) => !excluded.contains(track.videoId)))
            .take(5)
            .toList();

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            title: Semantics(
              header: true,
              child: Text(locals.musicPlaylistSuggestions),
            ),
            subtitle: _loadFailed
                ? Text(locals.musicPlaylistSuggestionsUnavailable)
                : !_loading && _candidates != null && tracks.isEmpty
                    ? Text(locals.musicPlaylistNoSuggestions)
                    : null,
            trailing: TextButton(
              key: const ValueKey('music-playlist-find-suggestions'),
              onPressed: _loading ? null : _find,
              child: Text(locals.musicPlaylistFindSuggestions),
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          for (final track in tracks)
            ListTile(
              key: ValueKey('music-playlist-suggestion-${track.videoId}'),
              title: Text(track.title),
              subtitle: Text(track.musicMetadata.artist),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: locals.addToPlaylist,
                  onPressed: _saving.contains(track.videoId)
                      ? null
                      : () => _add(track),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: locals.musicPlaylistDismissSuggestion,
                  onPressed: _saving.contains(track.videoId)
                      ? null
                      : () => _dismiss(track),
                ),
              ]),
            ),
        ],
      ),
    );
  }
}
