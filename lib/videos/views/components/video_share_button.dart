import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';

import '../../../utils.dart';

class VideoShareButton extends StatelessWidget {
  final Video video;
  final bool showTimestampOption;
  final bool inPlayer;

  const VideoShareButton(
      {super.key,
      required this.video,
      this.showTimestampOption = false,
      this.inPlayer = false});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: () => showSharingSheet(context, video,
          showTimestampOption: showTimestampOption, inPlayer: inPlayer),
      icon: const Icon(Icons.share),
    );
  }
}
