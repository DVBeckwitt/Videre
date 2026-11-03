import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../settings/models/db/server.dart';
import '../../../utils.dart';
import '../../../utils/invidious_image.dart';
import '../../../utils/views/components/selected_server.dart';
import '../../../videos/models/storyboard.dart';
import '../../../videos/models/video.dart';

/// Mounted only during seeking, so idle playback never downloads storyboards.
class SeekPreview extends StatelessWidget {
  final Video? video;
  final Duration position, duration;
  final double width;

  const SeekPreview(
      {super.key,
      required this.video,
      required this.position,
      required this.duration,
      this.width = 160});

  @override
  Widget build(BuildContext context) {
    final board = Storyboard.select(video?.storyboards ?? const [],
        width * MediaQuery.devicePixelRatioOf(context));
    final frame = board?.frameAt(position, duration);
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
            color: Colors.black87, borderRadius: BorderRadius.circular(8)),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (frame != null)
              SelectedServerBuilder(builder: (context, selected) {
                final server = video?.backendPlayback?.server ?? selected;
                return server == null
                    ? const SizedBox.shrink()
                    : _frame(context, frame, server);
              }),
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Text(prettyDurationCustom(position),
                    style: const TextStyle(color: Colors.white, fontSize: 13))),
          ]),
        ),
      ),
    );
  }

  Widget _frame(BuildContext context, StoryboardFrame frame, Server server) {
    final board = frame.storyboard;
    final url = invidiousImageUrl(frame.url, server);
    final cacheKey = invidiousImageCacheKey(url, server);
    final scale = width / board.width;
    final height = board.height * scale;
    final sheetWidth = width * board.columns;
    final sheetHeight = height * board.rows;
    final decodeWidth = math.min(board.width * board.columns,
        (sheetWidth * MediaQuery.devicePixelRatioOf(context)).ceil());
    return Image(
      key: ValueKey(cacheKey),
      image: ResizeImage.resizeIfNeeded(
          decodeWidth,
          null,
          CachedNetworkImageProvider(url,
              cacheKey: cacheKey, headers: server.headersForUrl(url))),
      width: sheetWidth,
      height: sheetHeight,
      fit: BoxFit.fitWidth,
      alignment: Alignment.topLeft,
      excludeFromSemantics: true,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      frameBuilder: (context, child, imageFrame, _) => imageFrame == null
          ? const SizedBox.shrink()
          : ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: width,
                height: height,
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: sheetWidth,
                  maxWidth: sheetWidth,
                  minHeight: sheetHeight,
                  maxHeight: sheetHeight,
                  child: Transform.translate(
                    offset: Offset(-frame.column * width, -frame.row * height),
                    child: child,
                  ),
                ),
              ),
            ),
    );
  }
}
