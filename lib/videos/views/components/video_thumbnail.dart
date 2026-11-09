import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:flutter/material.dart';

class VideoThumbnailView extends StatelessWidget {
  final String videoId;
  final List<String> thumbnails;
  final List<ImageObject>? images;
  final List<ImageObject>? musicThumbnails;
  final Widget? child;
  final BoxDecoration? decoration;

  const VideoThumbnailView(
      {super.key,
      required this.videoId,
      required this.thumbnails,
      this.images,
      this.musicThumbnails,
      this.child,
      this.decoration});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasMusicArtwork = musicThumbnails?.isNotEmpty == true;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Thumbnail(
            thumbnails: thumbnails,
            images: hasMusicArtwork ? musicThumbnails : images,
            useInvidiousProxy: !hasMusicArtwork,
            decoration: decoration ??
                BoxDecoration(
                  color: colors.secondaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
          ),
          if (child != null) child!,
        ],
      ),
    );
  }
}
