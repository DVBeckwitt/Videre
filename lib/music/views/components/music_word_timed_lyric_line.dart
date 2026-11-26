import 'package:clipious/music/models/music_lyrics.dart';
import 'package:flutter/material.dart';

/// Highlights one word at the reader's effective playback position.
/// Inactive lines pass a null position and retain their normal text style.
class MusicWordTimedLyricLine extends StatelessWidget {
  final String text;
  final List<MusicLyricWord> words;
  final Duration? position;

  /// Offset from the canonical cue text into the rendered text.
  final int wordOffset;
  final TextAlign? textAlign;

  const MusicWordTimedLyricLine({
    super.key,
    required this.text,
    required this.words,
    required this.position,
    this.wordOffset = 0,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    final position = this.position;
    if (position == null) return Text(text, textAlign: textAlign);

    MusicLyricWord? active;
    for (final word in words) {
      if (word.start > position) break;
      active = word;
    }
    if (active == null) return Text(text, textAlign: textAlign);
    final start = active.startOffset + wordOffset;
    final end = active.endOffset + wordOffset;
    if (start < 0 || end > text.length || start >= end) {
      return Text(text, textAlign: textAlign);
    }

    return Text.rich(
      TextSpan(children: [
        TextSpan(text: text.substring(0, start)),
        TextSpan(
          text: text.substring(start, end),
          style: const TextStyle(
            fontWeight: FontWeight.w900,
            decoration: TextDecoration.underline,
          ),
        ),
        TextSpan(text: text.substring(end)),
      ]),
      semanticsLabel: text,
      textAlign: textAlign,
    );
  }
}
