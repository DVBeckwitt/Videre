import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/views/components/thumbnail.dart';
import '../../models/music_track.dart';
import '../screens/music.dart';
import 'community_music_artwork.dart';
import 'music_library_actions.dart';

/// A recommendation shelf opens as a playable collection, following Muzza's
/// LocalPlaylistScreen queue behavior. Tracks form a normal Videre queue and
/// have no pretend catalog playlist ID.
class MusicRecommendationCollection extends StatefulWidget {
  final String title;
  final List<MusicTrack> tracks;
  final MusicTrack? cover;
  final Future<List<MusicTrack>> Function(bool Function() isCurrent)? load;
  final bool Function() isCurrent;
  final List<MusicTrack> Function(Iterable<MusicTrack>) eligible;
  final Listenable changes;

  const MusicRecommendationCollection({
    super.key,
    required this.title,
    required this.tracks,
    this.cover,
    this.load,
    required this.isCurrent,
    required this.eligible,
    required this.changes,
  });

  @override
  State<MusicRecommendationCollection> createState() =>
      _MusicRecommendationCollectionState();
}

class _MusicRecommendationCollectionState
    extends State<MusicRecommendationCollection> {
  List<MusicTrack>? _loaded;
  bool _loading = false;
  bool _failed = false;
  bool _starting = false;

  bool get _current =>
      mounted &&
      widget.isCurrent() &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  List<MusicTrack> get _tracks =>
      widget.isCurrent() ? widget.eligible(_loaded ?? widget.tracks) : const [];

  Future<void> _load() async {
    final load = widget.load;
    if (!_current || _loading || load == null) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final tracks = await load(() => _current);
      if (_current) setState(() => _loaded = tracks);
    } catch (_) {
      if (_current) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _play({String? from, bool shuffle = false}) async {
    if (!_current || _starting) return;
    final tracks = _tracks;
    if (tracks.isEmpty) return;
    final videos = [for (final track in tracks) track.toVideo()];
    if (shuffle) videos.shuffle();
    final index =
        from == null ? 0 : videos.indexWhere((v) => v.videoId == from);
    if (index < 0) return;
    setState(() => _starting = true);
    try {
      await MusicScreen.playTracks(context, videos, startIndex: index);
    } catch (_) {
      if (mounted && _current) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.musicPlaybackError)));
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Widget _art(MusicTrack? track, {required double size, bool songRow = false}) {
    final colors = Theme.of(context).colorScheme;
    final shape = BorderRadius.circular(6);
    final images = track?.displayThumbnails;
    final fallback = images == null || images.isEmpty
        ? DecoratedBox(
            decoration: BoxDecoration(
                color: colors.surfaceContainerHigh, borderRadius: shape),
            child: const Icon(Icons.queue_music_rounded),
          )
        : Thumbnail(
            images: images, decoration: BoxDecoration(borderRadius: shape));
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: songRow && track != null
            ? CommunityMusicArtwork(
                videoId: track.videoId,
                music: track.musicMetadata,
                durationSeconds: track.durationSeconds,
                fallback: fallback)
            : fallback,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Shortcuts(
        shortcuts: {
          LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
        },
        child: Scaffold(
          appBar: AppBar(title: Text(widget.title)),
          body: SafeArea(
            child: ListenableBuilder(
              listenable: widget.changes,
              builder: (context, _) {
                final locals = AppLocalizations.of(context)!;
                final tracks = _tracks;
                final current = widget.isCurrent();
                return CustomScrollView(slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                      child: Column(children: [
                        _art(tracks.firstOrNull ?? widget.cover, size: 180),
                        const SizedBox(height: 12),
                        if (tracks.isNotEmpty) ...[
                          Text(locals.musicTrackCount(tracks.length)),
                          const SizedBox(height: 12),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              FilledButton.icon(
                                key: const ValueKey('music-collection-play'),
                                onPressed: _starting ? null : () => _play(),
                                icon: const Icon(Icons.play_arrow_rounded),
                                label: Text(locals.musicPlayAll),
                              ),
                              if (tracks.length > 1)
                                FilledButton.tonalIcon(
                                  key: const ValueKey(
                                      'music-collection-shuffle'),
                                  onPressed: _starting
                                      ? null
                                      : () => _play(shuffle: true),
                                  icon: const Icon(Icons.shuffle_rounded),
                                  label: Text(locals.musicShuffle),
                                ),
                            ],
                          ),
                        ] else if (_loading)
                          const CircularProgressIndicator()
                        else if (current &&
                            widget.load != null &&
                            (_loaded == null || _failed)) ...[
                          if (_failed) Text(locals.musicLoadError),
                          FilledButton.tonalIcon(
                            key: const ValueKey('music-collection-load'),
                            onPressed: _load,
                            icon: Icon(_failed
                                ? Icons.refresh
                                : Icons.explore_outlined),
                            label: Text(
                                _failed ? locals.retry : locals.musicLoadMix),
                          ),
                        ] else
                          Text(locals.musicEmptyCollection),
                      ]),
                    ),
                  ),
                  SliverList.builder(
                    itemCount: tracks.length,
                    itemBuilder: (context, index) {
                      final song = tracks[index];
                      final artists = song.artists.join(', ');
                      return ListTile(
                        key: ValueKey('music-collection-${song.videoId}'),
                        onTap:
                            _starting ? null : () => _play(from: song.videoId),
                        onLongPress: _starting
                            ? null
                            : () => MusicLibraryActions.showSongMenu(
                                context, song.toVideo(),
                                onPlay: () => _play(from: song.videoId)),
                        leading: _art(song, size: 48, songRow: true),
                        title: Text(song.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: artists.isEmpty
                            ? null
                            : Text(artists,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: MusicLibraryActions(
                            videos: [song.toVideo()],
                            onPlay: () => _play(from: song.videoId)),
                      );
                    },
                  ),
                ]);
              },
            ),
          ),
        ),
      );
}
