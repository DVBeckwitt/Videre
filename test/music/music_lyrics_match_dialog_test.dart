import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/models/music_lyrics_match.dart';
import 'package:clipious/music/views/components/music_lyrics_match_dialog.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _track = MusicMetadata(
  title: 'Original title',
  artist: 'Original artist',
  album: 'Original album',
);

const _candidate = MusicLyricsMatch(
  id: 42,
  trackName: 'Alternate edition',
  artistName: 'Alternate artist',
  albumName: 'Alternate album',
  duration: Duration(minutes: 3),
  lyrics: MusicLyrics.synced([
    (start: Duration(seconds: 5), text: 'Preview lyric line'),
  ], source: 'LRCLIB'),
);

Future<void> _open(
  WidgetTester tester, {
  MusicLyricsSearch search = _findCandidate,
  MusicLyrics? currentLyrics,
  bool hasCorrection = false,
  required List<MusicLyricsCorrection?> saved,
}) async {
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<bool>(
            context: context,
            builder: (context) => MusicLyricsMatchDialog(
              track: _track,
              durationSeconds: 180,
              currentLyrics: currentLyrics,
              hasCorrection: hasCorrection,
              isCurrent: () => true,
              search: search,
              save: (correction) async => saved.add(correction),
            ),
          ),
          child: const Text('Open correction'),
        ),
      ),
    ),
  ));
  await _tap(tester, 'Open correction');
}

Future<List<MusicLyricsMatch>> _findCandidate({
  required String trackName,
  required String artistName,
  required String albumName,
  required int? durationSeconds,
  required bool Function() isCurrent,
}) async =>
    [_candidate];

Future<void> _tap(WidgetTester tester, String text) async {
  final target = find.text(text);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Correction searches on submit and previews before saving',
      (tester) async {
    final queries = <(String, String, String, int?)>[];
    final saved = <MusicLyricsCorrection?>[];
    await _open(
      tester,
      saved: saved,
      search: ({
        required trackName,
        required artistName,
        required albumName,
        required durationSeconds,
        required isCurrent,
      }) async {
        expect(isCurrent(), isTrue);
        queries.add((trackName, artistName, albumName, durationSeconds));
        return [_candidate];
      },
    );

    expect(find.text('Original title'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Revised title');
    expect(queries, isEmpty);
    await _tap(tester, 'Search');
    expect(
        queries, [('Revised title', 'Original artist', 'Original album', 180)]);
    expect(find.text('Preview lyric line'), findsNothing);

    await _tap(tester, 'Alternate edition');
    expect(find.text('Lyrics preview'), findsOneWidget);
    expect(find.text('LRCLIB'), findsOneWidget);
    expect(find.text('Preview lyric line'), findsOneWidget);
    expect(saved, isEmpty);

    await _tap(tester, 'Use this match');
    expect(saved.single?.lyrics, same(_candidate.lyrics));
    expect(saved.single?.edited, isFalse);
    expect(find.byType(MusicLyricsMatchDialog), findsNothing);
  });

  testWidgets('Timed lyric edits keep attribution and require explicit save',
      (tester) async {
    final saved = <MusicLyricsCorrection?>[];
    await _open(tester, saved: saved);
    await _tap(tester, 'Search');
    await _tap(tester, 'Alternate edition');
    await _tap(tester, 'Edit lyrics');
    await tester.enterText(find.byType(TextField), '[00:07.500]Edited line');
    await _tap(tester, 'Back');
    expect(saved, isEmpty);
    expect(find.text('Preview lyric line'), findsOneWidget);

    await _tap(tester, 'Edit lyrics');
    expect(find.text('[00:05.000]Preview lyric line'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '[00:07.500]Edited line');
    await _tap(tester, 'Save');
    final correction = saved.single!;
    expect(correction.edited, isTrue);
    expect(correction.lyrics.source, 'LRCLIB');
    expect(correction.lyrics.cues, [
      (start: const Duration(milliseconds: 7500), text: 'Edited line'),
    ]);
  });

  testWidgets('Discard and restore represent distinct persisted choices',
      (tester) async {
    final saved = <MusicLyricsCorrection?>[];
    await _open(tester, saved: saved, currentLyrics: _candidate.lyrics);
    await _tap(tester, 'Discard match');
    expect(saved.single?.lyrics.kind, MusicLyricsKind.unavailable);

    await _open(tester,
        saved: saved,
        hasCorrection: true,
        currentLyrics: const MusicLyrics.unavailable());
    await _tap(tester, 'Restore automatic matching');
    expect(saved, hasLength(2));
    expect(saved.last, isNull);
  });
}
