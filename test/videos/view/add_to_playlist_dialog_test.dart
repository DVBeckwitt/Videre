import 'dart:async';

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/videos/views/components/add_to_playlist_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _showPicker(
  WidgetTester tester,
  Future<void> Function(String) onAdd,
  List<bool?> results,
) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            results.add(await AddToPlaylistDialog.showAddToPlaylistDialog(
              context,
              videoId: 'video',
              playlists: const [
                Playlist(
                  title: 'Saved videos',
                  playlistId: 'server-playlist',
                  author: '',
                  videoCount: 0,
                ),
              ],
              onAdd: onAdd,
            ));
          },
          child: const Text('Open picker'),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Open picker'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('saving prevents repeated additions and playlist creation',
      (tester) async {
    final pending = Completer<void>();
    final added = <String>[];
    final results = <bool?>[];
    await _showPicker(tester, (id) {
      added.add(id);
      return pending.future;
    }, results);
    final playlist = find.widgetWithText(FilledButton, 'Saved videos');
    final create = find.widgetWithText(FilledButton, 'Create new playlist');

    // Exercise the guard before a frame has disabled the existing callbacks.
    await tester.tap(playlist);
    await tester.tap(playlist);
    await tester.tap(create);
    await tester.pumpAndSettle();

    expect(added, ['server-playlist']);
    expect(tester.widget<FilledButton>(playlist).onPressed, isNull);
    expect(tester.widget<FilledButton>(create).onPressed, isNull);
    expect(find.byType(Dialog), findsNothing);
    expect(results, isEmpty);

    pending.complete();
    await tester.pumpAndSettle();

    expect(results, [true]);
    expect(find.byType(AddToPlaylistDialog), findsNothing);
    expect(find.text('Open picker'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed additions leave the picker available for retry',
      (tester) async {
    final first = Completer<void>();
    final retry = Completer<void>();
    final results = <bool?>[];
    var attempts = 0;
    await _showPicker(tester, (_) {
      attempts++;
      return attempts == 1 ? first.future : retry.future;
    }, results);
    final playlist = find.widgetWithText(FilledButton, 'Saved videos');
    await tester.tap(playlist);
    first.completeError(StateError('Save failed'));
    await tester.pumpAndSettle();

    expect(results, isEmpty);
    expect(tester.widget<FilledButton>(playlist).onPressed, isNotNull);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Create new playlist'))
            .onPressed,
        isNotNull);

    await tester.tap(playlist);
    retry.complete();
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(results, [true]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('save completion does not dismiss a route above the picker',
      (tester) async {
    final pending = Completer<void>();
    final results = <bool?>[];
    await _showPicker(tester, (_) => pending.future, results);
    await tester.tap(find.widgetWithText(FilledButton, 'Saved videos'));
    await tester.pump();
    final pickerContext = tester.element(find.byType(AddToPlaylistDialog));
    unawaited(showDialog<String>(
      context: pickerContext,
      builder: (_) => const AlertDialog(content: Text('Another dialog')),
    ));
    await tester.pumpAndSettle();

    pending.complete();
    await tester.pumpAndSettle();

    expect(find.text('Another dialog'), findsOneWidget);
    expect(results, isEmpty);
    expect(tester.takeException(), isNull);

    Navigator.of(pickerContext).pop();
    await tester.pumpAndSettle();
    expect(find.byType(AddToPlaylistDialog), findsOneWidget);
    Navigator.of(pickerContext).pop();
    await tester.pumpAndSettle();
    expect(results, [null]);
  });
}
