import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app;
import 'package:clipious/music/views/screens/music_playlist_reorder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _rows = [
  (id: 'first-copy', title: 'Song A', artist: 'Artist'),
  (id: 'other-song', title: 'Song B', artist: 'Artist'),
  (id: 'second-copy', title: 'Song A', artist: 'Artist'),
];

void main() {
  testWidgets('moving an identical copy can be canceled or saved by ID',
      (tester) async {
    var writes = 0;
    List<String>? saved;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Builder(builder: (context) {
        return TextButton(
          onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute(
              builder: (_) => MusicPlaylistReorder(
                    rows: _rows,
                    onSave: (order) async {
                      writes++;
                      saved = order;
                      return true;
                    },
                  ))),
          child: const Text('Open editor'),
        );
      })),
    ));

    final previousTv = app.isTv;
    app.isTv = true;
    addTearDown(() => app.isTv = previousTv);
    const secondCopy = ValueKey(('music-playlist-move', 'second-copy'));

    Future<void> moveCopy() async {
      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();
      expect(find.byType(ReorderableDragStartListener), findsNothing);
      await tester.tap(find.byKey(secondCopy));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move up'));
      await tester.pumpAndSettle();
      final secondCopyPosition =
          tester.getTopLeft(find.byKey(const ValueKey('second-copy')));
      final otherPosition =
          tester.getTopLeft(find.byKey(const ValueKey('other-song')));
      expect(secondCopyPosition.dy, lessThan(otherPosition.dy));
      expect(writes, 0);
    }

    await moveCopy();
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(writes, 0);

    await moveCopy();
    await tester.tap(find.byKey(const ValueKey('music-playlist-reorder-save')));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(saved, ['first-copy', 'second-copy', 'other-song']);
    expect(find.byType(MusicPlaylistReorder), findsNothing);
  });
}
