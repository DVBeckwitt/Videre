import 'package:auto_route/auto_route.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/views/components/video_queue.dart';
import 'package:flutter/material.dart';

@RoutePage()
class VideoQueueScreen extends StatelessWidget {
  const VideoQueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context)!.videoQueue)),
      body: const SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: innerHorizontalPadding),
          child: VideoQueue(),
        ),
      ),
    );
  }
}
