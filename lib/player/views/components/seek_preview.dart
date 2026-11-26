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
  static const _frameGap = 2.0;

  final Video? video;
  final Duration position, duration;

  /// Maximum width of the three frames and the gaps between them.
  final double width;

  const SeekPreview(
      {super.key,
      required this.video,
      required this.position,
      required this.duration,
      this.width = 320});

  @override
  Widget build(BuildContext context) {
    final boards = video?.storyboards ?? const <Storyboard>[];
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
            color: Colors.black87, borderRadius: BorderRadius.circular(8)),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (boards.isNotEmpty)
              SelectedServerBuilder(builder: (context, selected) {
                final server = video?.backendPlayback?.server ?? selected;
                if (server == null) return const SizedBox.shrink();
                return LayoutBuilder(builder: (context, constraints) {
                  final frameWidth =
                      (math.min(width, constraints.maxWidth) - 2 * _frameGap) /
                          3;
                  if (frameWidth <= 0) return const SizedBox.shrink();
                  return _filmstrip(context, boards, server, frameWidth);
                });
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

  Widget _filmstrip(BuildContext context, List<Storyboard> boards,
      Server server, double frameWidth) {
    // A rejected larger source must not hide a smaller storyboard
    // that the instance can serve privately.
    final available = boards.where((board) {
      final frame = board.frameAt(position, duration);
      return frame != null &&
          invidiousImageUrl(frame.url, server)?.isNotEmpty == true;
    }).toList();
    final board = Storyboard.select(
        available, frameWidth * MediaQuery.devicePixelRatioOf(context));
    if (board == null) return const SizedBox.shrink();

    final center = board.frameAt(position, duration);
    final before = board.frameAt(position, duration, offset: -1);
    final after = board.frameAt(position, duration, offset: 1);
    // Mount the neighboring crops once the current sheet has decoded.
    return _frame(context, center, server, frameWidth, wrap: (context, crop) {
      final current = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white70, width: 2),
          borderRadius: BorderRadius.circular(4),
        ),
        child: crop,
      );
      if (before == null && after == null) return current;
      // Keep the current frame centered when either neighboring slot is empty.
      return Row(mainAxisSize: MainAxisSize.min, spacing: _frameGap, children: [
        SizedBox(
            width: frameWidth,
            child: _frame(context, before, server, frameWidth)),
        current,
        SizedBox(
            width: frameWidth,
            child: _frame(context, after, server, frameWidth)),
      ]);
    });
  }

  Widget _frame(BuildContext context, StoryboardFrame? frame, Server server,
      double frameWidth,
      {Widget Function(BuildContext, Widget)? wrap}) {
    if (frame == null) return const SizedBox.shrink();
    final board = frame.storyboard;
    final url = invidiousImageUrl(frame.url, server);
    if (url == null || url.isEmpty) return const SizedBox.shrink();
    final cacheKey = invidiousImageCacheKey(url, server);
    final scale = frameWidth / board.width;
    final height = board.height * scale;
    final sheetWidth = frameWidth * board.columns;
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
      frameBuilder: (context, child, imageFrame, _) {
        if (imageFrame == null) return const SizedBox.shrink();
        final crop = ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            width: frameWidth,
            height: height,
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: sheetWidth,
              maxWidth: sheetWidth,
              minHeight: sheetHeight,
              maxHeight: sheetHeight,
              child: Transform.translate(
                offset: Offset(-frame.column * frameWidth, -frame.row * height),
                child: child,
              ),
            ),
          ),
        );
        return wrap?.call(context, crop) ?? crop;
      },
    );
  }
}
