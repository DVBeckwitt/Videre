import 'package:clipious/globals.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/videos/models/dislike.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'video_metrics.dart';

class VideoDislikeMetrics extends StatefulWidget {
  final Video video;
  final TextStyle? style;
  final double iconSize;

  const VideoDislikeMetrics({
    super.key,
    required this.video,
    this.style,
    this.iconSize = 15,
  });

  @override
  State<VideoDislikeMetrics> createState() => _VideoDislikeMetricsState();
}

class _VideoDislikeMetricsState extends State<VideoDislikeMetrics> {
  (String, bool, String)? _requestKey;
  Future<Dislike>? _request;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.watch<SettingsCubit>();
    _updateRequest();
  }

  @override
  void didUpdateWidget(VideoDislikeMetrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateRequest();
  }

  void _updateRequest() {
    final settings = context.read<SettingsCubit>().state;
    final key = (
      widget.video.videoId,
      settings.useReturnYoutubeDislike,
      settings.returnYoutubeDislikeUrl,
    );
    if (_requestKey == key) return;
    _requestKey = key;
    _request = settings.useReturnYoutubeDislike
        ? service.getDislikes(widget.video.videoId)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Dislike>(
      key: ValueKey(_requestKey),
      future: _request,
      builder: (context, snapshot) => VideoMetrics(
        video: widget.video,
        dislikes: snapshot.data?.dislikes,
        style: widget.style,
        iconSize: widget.iconSize,
      ),
    );
  }
}
