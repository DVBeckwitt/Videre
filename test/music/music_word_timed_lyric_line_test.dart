import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/views/components/music_word_timed_lyric_line.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const line = 'Go  🎵 home!';
  const words = <MusicLyricWord>[
    (start: Duration(seconds: 1), startOffset: 0, endOffset: 2),
    (start: Duration(seconds: 2), startOffset: 4, endOffset: 6),
    (start: Duration(seconds: 3), startOffset: 7, endOffset: 12),
  ];

  testWidgets('highlights the active word while preserving text and semantics',
      (tester) async {
    final semantics = tester.ensureSemantics();

    Future<void> pump(Duration? position) => tester.pumpWidget(MaterialApp(
          home: MusicWordTimedLyricLine(
            text: line,
            words: words,
            position: position,
            textAlign: TextAlign.center,
          ),
        ));

    void expectActiveWord(String? word) {
      final label = tester.widget<Text>(find.text(line));
      expect(label.textAlign, TextAlign.center);
      if (word == null) {
        expect(label.textSpan, isNull);
        return;
      }
      final span = label.textSpan! as TextSpan;
      expect(span.toPlainText(), line);
      final emphasized = span.children!.cast<TextSpan>().singleWhere(
          (child) => child.style?.decoration == TextDecoration.underline);
      expect(emphasized.text, word);
      expect(find.bySemanticsLabel(line), findsOneWidget);
    }

    try {
      await pump(const Duration(milliseconds: 999));
      expectActiveWord(null);
      await pump(const Duration(milliseconds: 1999));
      expectActiveWord('Go');
      await pump(const Duration(seconds: 2));
      expectActiveWord('🎵');
      await pump(const Duration(seconds: 4));
      expectActiveWord('home!');
      await pump(const Duration(seconds: 1));
      expectActiveWord('Go');
      await pump(null);
      expectActiveWord(null);
    } finally {
      semantics.dispose();
    }
  });
}
