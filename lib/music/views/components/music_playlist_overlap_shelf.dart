import 'package:clipious/app/states/app.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_playlist.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/views/components/music_catalog_cards.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class MusicPlaylistOverlapShelf extends StatefulWidget {
  final String playlistId;
  final ValueChanged<String> onOpen;

  const MusicPlaylistOverlapShelf({
    super.key,
    required this.playlistId,
    required this.onOpen,
  });

  @override
  State<MusicPlaylistOverlapShelf> createState() =>
      _MusicPlaylistOverlapShelfState();
}

class _MusicPlaylistOverlapShelfState extends State<MusicPlaylistOverlapShelf> {
  late final MusicLibrarySession _session;
  List<String> _candidates = const [];
  Future<List<MusicPlaylist>>? _results;

  @override
  void initState() {
    super.initState();
    _session = MusicLibrarySession(context.read<AppCubit>());
    _session.library.changes.addListener(_refresh);
    _refresh();
  }

  @override
  void dispose() {
    _session.library.changes.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    final candidates = _session.library.entries
        .where((entry) =>
            entry.kind == MusicLibraryKind.playlist &&
            entry.id != widget.playlistId &&
            isMusicPlaylistOverlapCandidate(entry.id))
        .map((entry) => entry.id)
        .take(musicPlaylistOverlapCandidateLimit)
        .toList();
    if (listEquals(_candidates, candidates)) return;
    setState(() {
      _candidates = candidates;
      _results = candidates.isEmpty || !_session.isCurrent
          ? null
          : musicCatalogService.findPlaylistsWithSongsInCommon(
              widget.playlistId, candidates,
              isCurrent: () =>
                  mounted &&
                  _session.isCurrent &&
                  identical(_candidates, candidates));
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<MusicPlaylist>>(
      future: _results,
      builder: (context, snapshot) {
        if (!_session.isCurrent ||
            snapshot.connectionState != ConnectionState.done ||
            snapshot.data?.isNotEmpty != true) {
          return const SizedBox.shrink();
        }
        final matches = snapshot.data!;
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  AppLocalizations.of(context)!.musicPlaylistsWithSongsInCommon,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 8),
              MusicCatalogShelf(
                itemCount: matches.length,
                itemBuilder: (context, index) {
                  final playlist = matches[index];
                  return MusicCatalogCard(
                    key: ValueKey(('music-playlist-overlap', playlist.id)),
                    title: playlist.title,
                    subtitle: playlist.author,
                    thumbnails: playlist.thumbnails,
                    onOpen: () {
                      if (_session.isCurrent &&
                          _session.library.contains(
                              MusicLibraryKind.playlist, playlist.id)) {
                        widget.onOpen(playlist.id);
                      }
                    },
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
