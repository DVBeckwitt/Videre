import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/views/components/thumbnail.dart';
import '../../models/music_card_origin.dart';
import '../../models/music_track.dart';
import '../../services/music_visibility.dart';
import '../screens/music.dart';
import 'community_music_artwork.dart';
import 'music_card_playback.dart';
import 'music_collection_panes.dart';
import 'music_discovery_snooze.dart';
import 'music_library_actions.dart';
import 'music_status_title.dart';
import 'music_song_row_swipe.dart';
import 'music_screen_privacy.dart';

/// A recommendation shelf opens as a playable collection, following Muzza's
/// LocalPlaylistScreen queue behavior. Tracks form a normal Videre queue and
/// have no pretend catalog playlist ID.
class MusicRecommendationCollection extends StatefulWidget {
  final String title;
  final String? collectionId;
  final List<MusicTrack> tracks;
  final bool Function() isCurrent;
  final List<MusicTrack> Function(Iterable<MusicTrack>) eligible;
  final Listenable changes;
  final MusicVisibility? snooze;

  const MusicRecommendationCollection({
    super.key,
    required this.title,
    this.collectionId,
    required this.tracks,
    required this.isCurrent,
    required this.eligible,
    required this.changes,
    this.snooze,
  });

  @override
  State<MusicRecommendationCollection> createState() =>
      _MusicRecommendationCollectionState();
}

class _MusicRecommendationCollectionState
    extends State<MusicRecommendationCollection> {
  int _playRequest = 0;

  bool get _current =>
      mounted &&
      widget.isCurrent() &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  List<MusicTrack> get _tracks =>
      widget.isCurrent() ? widget.eligible(widget.tracks) : const [];

  MusicCardOrigin? _origin([String? entryId]) {
    final id = widget.collectionId;
    return id == null
        ? null
        : (
            surface: MusicCardSurface.recommendationCollection,
            collectionId: id,
            entryId: entryId,
          );
  }

  Future<void> _play(
      {String? from, bool shuffle = false, bool songTap = false}) async {
    if (!_current) return;
    final tracks = _tracks;
    if (tracks.isEmpty) return;
    final videos = [for (final track in tracks) track.toVideo()];
    if (shuffle) videos.shuffle();
    final index =
        from == null ? 0 : videos.indexWhere((v) => v.videoId == from);
    if (index < 0) return;
    final origin = shuffle ? null : _origin(from);
    final request = ++_playRequest;
    try {
      await MusicScreen.playTracks(context, videos,
          queueTitle: widget.title,
          startIndex: index,
          cardOrigin: origin,
          songTap: songTap);
    } catch (_) {
      if (mounted && request == _playRequest && _current) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.musicPlaybackError)));
      }
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
            musicArtwork: true,
            images: images,
            decoration: BoxDecoration(borderRadius: shape));
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
  Widget build(BuildContext context) =>
      MusicScreenPrivacySurface(child: _buildCollection(context));

  Widget _buildCollection(BuildContext context) => Shortcuts(
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
                final playAll = _origin();
                final playing = playAll == null
                    ? null
                    : watchMusicCardPlaying(context, playAll);
                final details = Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                  child: Column(children: [
                    if (MediaQuery.sizeOf(context).height >= 480) ...[
                      _art(tracks.firstOrNull, size: 180),
                      const SizedBox(height: 12),
                    ],
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
                            onPressed: playAll == null
                                ? () => _play()
                                : () => activateMusicCard(
                                    context, playAll, () => _play()),
                            icon: Icon(playing == true
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded),
                            label: Text(
                                musicCardPlaybackHint(context, playing) ??
                                    locals.musicPlayAll),
                          ),
                          if (tracks.length > 1)
                            FilledButton.tonalIcon(
                              key: const ValueKey('music-collection-shuffle'),
                              onPressed: () => _play(shuffle: true),
                              icon: const Icon(Icons.shuffle_rounded),
                              label: Text(locals.musicShuffle),
                            ),
                        ],
                      ),
                    ] else
                      Text(locals.musicEmptyCollection),
                  ]),
                );
                final songs = SliverList.builder(
                  key: const ValueKey('music-recommendation-tracks'),
                  itemCount: tracks.length,
                  itemBuilder: (_, index) => Builder(builder: (context) {
                    final song = tracks[index];
                    final video = song.toVideo();
                    final artists = song.artists.join(', ');
                    final visibility = widget.snooze;
                    final recommendation = visibility == null
                        ? null
                        : MusicSongRecommendation(
                            isCurrent: () => _current,
                            onSnooze: () => showMusicDiscoverySnooze(
                                context, visibility, song, () => _current),
                          );
                    final origin = _origin(song.videoId);
                    final playing = origin == null
                        ? null
                        : watchMusicCardPlaying(context, origin);
                    final indicator = musicCardPlaybackIcon(playing);
                    Future<void> start() => _play(from: song.videoId);
                    Future<void> tap() =>
                        _play(from: song.videoId, songTap: true);
                    void activate() {
                      if (!_current) return;
                      if (origin == null) {
                        tap();
                      } else {
                        activateMusicCard(context, origin, tap);
                      }
                    }

                    final tile = Semantics(
                      onTapHint: musicCardPlaybackHint(context, playing),
                      child: ListTile(
                        onTap: activate,
                        onLongPress: () => MusicLibraryActions.showSongMenu(
                            context, video,
                            recommendation: recommendation, onPlay: start),
                        leading: _art(song, size: 48, songRow: true),
                        title: MusicStatusTitle.song(
                            video: video,
                            child: Text(song.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis)),
                        subtitle: artists.isEmpty
                            ? null
                            : Text(artists,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing:
                            Row(mainAxisSize: MainAxisSize.min, children: [
                          if (indicator != null) indicator,
                          MusicLibraryActions(
                              videos: [video],
                              recommendation: recommendation,
                              onPlay: start),
                        ]),
                      ),
                    );
                    return MusicSongRowSwipe(
                      key: ValueKey('music-collection-${song.videoId}'),
                      onAction: (action) =>
                          MusicLibraryActions.queueSong(context, video, action),
                      child: tile,
                    );
                  }),
                );
                return MusicCollectionPanes(
                  details: details,
                  buildTracks: (_, split) => CustomScrollView(
                    slivers: [
                      if (!split) SliverToBoxAdapter(child: details),
                      songs,
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
}
