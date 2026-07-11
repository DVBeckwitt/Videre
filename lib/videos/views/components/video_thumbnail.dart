import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:flutter/material.dart';

class VideoThumbnailView extends StatelessWidget {
  final String videoId;
  final List<String> thumbnails;
  final Widget? child;
  final BoxDecoration? decoration;

  const VideoThumbnailView(
      {super.key,
      required this.videoId,
      required this.thumbnails,
      this.child,
      this.decoration});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Thumbnail(
            thumbnails: thumbnails,
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
