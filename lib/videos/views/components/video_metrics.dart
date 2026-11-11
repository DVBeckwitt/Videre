import 'package:duration/duration.dart';
import 'package:flutter/material.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';

import '../../../utils.dart';
import '../../models/video.dart';

class VideoMetrics extends StatelessWidget {
  final Video? video;
  final int? dislikes;
  final TextStyle? style;
  final double iconSize;
  final bool showDuration;

  const VideoMetrics(
      {super.key,
      this.video,
      this.dislikes,
      this.style,
      this.showDuration = true,
      this.iconSize = 20});

  Widget metric(IconData icon, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: iconSize),
          const SizedBox(width: 4),
          Flexible(child: Text(label, style: style)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    AppLocalizations locals = AppLocalizations.of(context)!;

    final now = DateTime.now();
    final premiere = video?.premiereTimestamp;
    final startsAt = premiere == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(premiere * 1000);
    List<Widget> metrics = [];
    if ((video?.isUpcoming ?? false) &&
        startsAt != null &&
        startsAt.isAfter(now)) {
      metrics = [
        Text(
          locals.premieresIn(
              prettyDuration(startsAt.difference(now), maxUnits: 1)),
          style: style,
        ),
      ];
    } else {
      var length = video?.lengthSeconds ?? 0;
      if (showDuration && length > 0) {
        metrics.add(metric(
            Icons.timer, prettyDurationCustom(Duration(seconds: length))));
      }

      var views = video?.viewCount ?? 0;
      if (views > 0) {
        metrics.add(metric(Icons.visibility, compactCurrency.format(views)));
      }

      var likes = video?.likeCount ?? 0;
      if (likes > 0) {
        metrics.add(metric(Icons.thumb_up, compactCurrency.format(likes)));
      }

      if (dislikes != null && dislikes! >= 0) {
        metrics.add(metric(Icons.thumb_down,
            compactCurrency.format(dislikes).replaceAll(".00", "")));
      }

      var date = video?.publishedText ?? '';
      if ((date.isNotEmpty && !date.startsWith('0')) ||
          video?.liveNow == true) {
        metrics.add(
          (video?.liveNow ?? false)
              ? Visibility(
                  visible: video!.liveNow ?? false,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8.0, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.podcasts,
                            size: iconSize,
                          ),
                          Flexible(
                              child: Padding(
                            padding: const EdgeInsets.only(left: 8.0),
                            child: Text(
                              locals.streamIsLive,
                              style: style,
                            ),
                          )),
                        ],
                      ),
                    ),
                  ),
                )
              : Text(
                  date,
                  style: style,
                ),
        );
      }
    }

    return metrics.isNotEmpty
        ? Wrap(
            spacing: 16,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: metrics,
          )
        : const SizedBox.shrink();
  }
}
