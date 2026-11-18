import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/views/components/community_music_artwork.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/utils/views/components/channel_avatar.dart';
import 'package:flutter/material.dart';

/// A focusable song, artist, or collection from the Music catalog.
class MusicCatalogCard extends StatefulWidget {
  final String title;
  final String? subtitle;
  final List<ImageObject> thumbnails;
  final MusicTrack? song;
  final VoidCallback onOpen;
  final VoidCallback? onLongPress;
  final bool artist;
  final Widget? badge;
  final bool showPlayIndicator;

  const MusicCatalogCard({
    super.key,
    required this.title,
    this.thumbnails = const [],
    this.song,
    required this.onOpen,
    this.onLongPress,
    this.subtitle,
    this.artist = false,
    this.badge,
    this.showPlayIndicator = false,
  });

  @override
  State<MusicCatalogCard> createState() => _MusicCatalogCardState();
}

class _MusicCatalogCardState extends State<MusicCatalogCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final radius = BorderRadius.circular(widget.artist ? 1000 : 6);
    final song = widget.song;
    final images = song?.displayThumbnails ?? widget.thumbnails;
    final artwork = widget.artist
        ? ChannelAvatar(name: widget.title, images: images, instanceOnly: true)
        : images.isEmpty
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHigh,
                  borderRadius: radius,
                ),
                child: Icon(Icons.album_outlined,
                    size: 40, color: colors.onSurfaceVariant),
              )
            : Thumbnail(
                images: images,
                instanceOnly: true,
                decoration: BoxDecoration(borderRadius: radius),
              );
    final card = Semantics(
      button: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: widget.onOpen,
          onLongPress: widget.onLongPress,
          onFocusChange: (focused) {
            setState(() => _focused = focused);
            if (focused) {
              Scrollable.ensureVisible(context, alignment: 0.5);
            }
          },
          borderRadius: BorderRadius.circular(6),
          child: Container(
            foregroundDecoration: _focused
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: colors.primary, width: 2),
                  )
                : null,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: ExcludeSemantics(
                    child: Stack(fit: StackFit.expand, children: [
                      if (song == null)
                        artwork
                      else
                        CommunityMusicArtwork(
                          videoId: song.videoId,
                          music: song.musicMetadata,
                          durationSeconds: song.durationSeconds,
                          fallback: artwork,
                        ),
                      if (widget.showPlayIndicator)
                        const PositionedDirectional(
                          end: 8,
                          bottom: 8,
                          child: CircleAvatar(
                            radius: 18,
                            backgroundColor: Colors.black54,
                            foregroundColor: Colors.white,
                            child: Icon(Icons.play_arrow_rounded, size: 22),
                          ),
                        ),
                    ]),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.title,
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(height: 1.3, fontWeight: FontWeight.w700),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (widget.subtitle?.isNotEmpty == true) ...[
                  const SizedBox(height: 2),
                  Text(
                    widget.subtitle!,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: colors.onSurfaceVariant, height: 1.3),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (widget.badge case final badge?) {
      return Stack(
        children: [
          card,
          PositionedDirectional(
            top: 8,
            start: 8,
            end: 8,
            child: Align(alignment: AlignmentDirectional.topEnd, child: badge),
          ),
        ],
      );
    }
    return card;
  }
}

class MusicCatalogShelf extends StatelessWidget {
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  const MusicCatalogShelf(
      {super.key, required this.itemCount, required this.itemBuilder});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth < 600 ? 128.0 : 160.0;
      final scaler = MediaQuery.textScalerOf(context);
      final text = Theme.of(context).textTheme;
      final height = width +
          16 +
          scaler.scale(text.bodyLarge!.fontSize!) * 1.3 * 2 +
          scaler.scale(text.bodyMedium!.fontSize!) * 1.3 * 2;
      // A real nested horizontal scrollable owns shelf drags, including at its
      // ends, so a gesture on artwork cannot switch the enclosing app page.
      return SizedBox(
        height: height,
        child: ListView.separated(
          primary: false,
          scrollDirection: Axis.horizontal,
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: itemCount,
          separatorBuilder: (_, __) => const SizedBox(width: 24),
          itemBuilder: (context, index) => SizedBox(
            width: width,
            child: itemBuilder(context, index),
          ),
        ),
      );
    });
  }
}

class MusicCatalogGrid extends StatelessWidget {
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  const MusicCatalogGrid(
      {super.key, required this.itemCount, required this.itemBuilder});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      const gap = 14.0;
      final columns = (constraints.maxWidth / 170).floor().clamp(2, 6);
      final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: 20,
        children: [
          for (var index = 0; index < itemCount; index++)
            SizedBox(width: width, child: itemBuilder(context, index)),
        ],
      );
    });
  }
}
