import 'package:clipious/utils.dart';
import 'package:flutter/material.dart';

class VideoDurationBadge extends StatelessWidget {
  final int? lengthSeconds;
  final bool compact;

  const VideoDurationBadge({
    super.key,
    required this.lengthSeconds,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final seconds = lengthSeconds ?? 0;
    if (seconds <= 0) return const SizedBox.shrink();

    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.all(compact ? 4 : 8),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Text(
              prettyDurationCustom(Duration(seconds: seconds)),
              style: (compact ? textTheme.labelSmall : textTheme.bodySmall)
                  ?.copyWith(color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}
