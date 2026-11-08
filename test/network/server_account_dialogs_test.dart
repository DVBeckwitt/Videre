import 'dart:async';
import 'dart:convert';

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/views/components/server_account_dialogs.dart';
import 'package:clipious/utils/views/tv/components/tv_button.dart';
import 'package:clipious/utils/views/tv/components/tv_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> selectAction(
      WidgetTester tester, String label, bool television) async {
    final text = find.text(label);
    if (television) {
      final button = find.ancestor(of: text, matching: find.byType(TvButton));
      final contents =
          find.descendant(of: button, matching: find.byType(Align)).first;
      Focus.of(tester.element(contents)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
    } else {
      await tester.tap(text);
    }
  }

  Future<void> showHost(WidgetTester tester,
      {required bool television,
      required Future<void> Function(String, String) save,
      required VoidCallback onDialogClosed}) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Column(children: [
          const Text('Outer settings route'),
          Expanded(
            child: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (context) => Scaffold(
                  body: Column(children: [
                    const Text('Server settings route'),
                    TextButton(
                      onPressed: () => showServerBasicAuthDialog(context, save,
                              television: television)
                          .whenComplete(onDialogClosed),
                      child: const Text('Open Basic authentication'),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    ));
    await tester.tap(find.text('Open Basic authentication'));
    await tester.pumpAndSettle();
  }

  Future<void> enterCredentials(WidgetTester tester, bool television) async {
    const username = 'test-person';
    const password = 'test-päss:word';
    if (television) {
      final fields =
          tester.widgetList<TvTextField>(find.byType(TvTextField)).toList();
      expect(fields, hasLength(2));
      expect(fields[0].obscureText, isFalse);
      expect(fields[1].obscureText, isTrue);
      expect(fields[0].autofillHints,
          [AutofillHints.username, AutofillHints.email]);
      expect(fields[1].autofillHints, [AutofillHints.password]);
      expect(fields.every((field) => field.autocorrect == false), isTrue);
      // The TV keyboard route edits these same controllers.
      fields[0].controller.text = username;
      fields[1].controller.text = password;
    } else {
      final fields =
          tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields, hasLength(2));
      expect(fields[0].obscureText, isFalse);
      expect(fields[1].obscureText, isTrue);
      expect(fields[0].autofillHints,
          [AutofillHints.username, AutofillHints.email]);
      expect(fields[1].autofillHints, [AutofillHints.password]);
      expect(fields.every((field) => field.autocorrect == false), isTrue);
      await tester.enterText(find.byType(TextField).at(0), username);
      await tester.enterText(find.byType(TextField).at(1), password);
    }
  }

  for (final television in [false, true]) {
    final platform = television ? 'TV' : 'phone';

    testWidgets(
        '$platform Basic authentication protects input and waits for saving before closing',
        (tester) async {
      final saved = <(String, String)>[];
      final saving = Completer<void>();
      var closed = false;
      await showHost(tester,
          television: television,
          save: (name, value) {
            saved.add((name, value));
            return saving.future;
          },
          onDialogClosed: () => closed = true);
      await enterCredentials(tester, television);
      await selectAction(tester, 'Add', television);
      await tester.pump();

      expect(saved, hasLength(1));
      expect(saved.single.$1, 'Authorization');
      final value = saved.single.$2;
      expect(value, startsWith('Basic '));
      expect(utf8.decode(base64Decode(value.substring(6))),
          'test-person:test-päss:word');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(closed, isFalse);

      saving.complete();
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Outer settings route'), findsOneWidget);
      expect(find.text('Server settings route'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '$platform cancelling Basic authentication saves no credentials',
        (tester) async {
      var saves = 0;
      var closed = false;
      await showHost(tester,
          television: television,
          save: (name, value) async {
            saves++;
          },
          onDialogClosed: () => closed = true);
      await enterCredentials(tester, television);
      await selectAction(tester, 'Cancel', television);
      await tester.pumpAndSettle();

      expect(saves, 0);
      expect(closed, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Outer settings route'), findsOneWidget);
      expect(find.text('Server settings route'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
