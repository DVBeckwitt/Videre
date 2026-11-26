import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_lyrics.dart';
import 'package:flutter/material.dart';

/// Displays attribution and supplied translations with the cue they belong to.
class MusicLyricCueDetails extends StatelessWidget {
  final MusicLyricCueMetadata metadata;
  final TextAlign alignment;
  final Widget child;

  const MusicLyricCueDetails({
    super.key,
    required this.metadata,
    required this.alignment,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final attribution = [
      if (metadata.voice case final voice?) voice,
      if (metadata.isBackgroundVocal)
        AppLocalizations.of(context)!.musicLyricsBackgroundVocals,
    ].join(' · ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (attribution.isNotEmpty)
          Text(attribution, style: textTheme.labelMedium, textAlign: alignment),
        child,
        for (final translation in metadata.translations)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              translation.text,
              style: textTheme.bodyMedium,
              textAlign: alignment,
            ),
          ),
      ],
    );
  }
}
