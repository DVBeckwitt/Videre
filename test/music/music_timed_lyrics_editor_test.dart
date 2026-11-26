import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/services/music_timed_lyrics_draft.dart';
import 'package:clipious/music/views/components/music_timed_lyrics_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _duration = Duration(seconds: 12);

void main() {
  test('retimes the word at the caret without changing lyric text', () {
    const input = '[00:02.000]<00:02.000>First 🙂 word';
    final edited = stampMusicTimedLyricsDraft(input,
        caretOffset: input.indexOf('🙂') + 1,
        position: const Duration(milliseconds: 3150),
        playbackDuration: _duration,
        word: true)!;
    expect(edited.text, '[00:02.000]<00:02.000>First <00:03.150>🙂 word');
    expect(validatedMusicTimedLyricsDraft(edited.text, _duration), edited.text);
  });

  testWidgets('timestamps the draft and saves only valid lines',
      (tester) async {
    String? saved;
    var position = const Duration(milliseconds: 1250);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showMusicTimedLyricsEditor(
            context,
            songTitle: 'Test recording',
            initialText: 'First word',
            playbackDuration: _duration,
            isCurrent: () => true,
            playbackPosition: () => position,
            save: (draft) async {
              saved = draft;
              return true;
            },
          ),
          child: const Text('Open'),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(TextField));
    final locals = AppLocalizations.of(context)!;
    await tester.tap(find.text(locals.save));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(find.text(locals.musicLyricsDraftInvalid), findsOneWidget);

    await tester.tap(find.text(locals.musicLyricsStampLine));
    await tester.pumpAndSettle();
    final controller =
        tester.widget<TextField>(find.byType(TextField)).controller!;
    expect(controller.text, '[00:01.250]First word');
    controller.selection =
        TextSelection.collapsed(offset: controller.text.indexOf('word') + 2);
    position = const Duration(milliseconds: 2750);
    await tester.tap(find.text(locals.musicLyricsStampWord));
    await tester.tap(find.text(locals.save));
    await tester.pumpAndSettle();
    expect(saved, '[00:01.250]First <00:02.750>word');
    expect(find.text('Open'), findsOneWidget);
  });
}
