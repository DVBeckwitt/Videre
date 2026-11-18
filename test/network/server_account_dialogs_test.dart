import 'dart:async';
import 'dart:convert';

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/server_settings.dart';
import 'package:clipious/settings/views/components/server_account_dialogs.dart';
import 'package:clipious/settings/views/tv/screens/manage_single_server.dart';
import 'package:clipious/utils/views/tv/components/tv_button.dart';
import 'package:clipious/utils/views/tv/components/tv_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _PendingCookieSettings extends Cubit<ServerSettingsState>
    implements ServerSettingsCubit {
  final Future<void> pending;
  var saves = 0;

  _PendingCookieSettings(this.pending)
      : super(const ServerSettingsState(
            server: Server(url: 'https://instance.example')));

  @override
  Future<void> logInWithCookie(String username, String password) async {
    saves++;
    emit(state.copyWith(authenticating: true));
    try {
      await pending;
    } finally {
      emit(state.copyWith(authenticating: false));
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

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

  for (final fails in [false, true]) {
    testWidgets(
        'TV cookie completion preserves a newer keyboard route (failure: $fails)',
        (tester) async {
      final saving = Completer<void>();
      final settings = _PendingCookieSettings(saving.future);
      addTearDown(settings.close);
      const screen = TvManageSingleServerScreen(
          server: Server(url: 'https://instance.example'));
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider<ServerSettingsCubit>.value(
          value: settings,
          child: Builder(
              builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () =>
                          screen.showLogInWithCookiesDialog(context),
                      child: const Text('Open cookie login'),
                    ),
                  )),
        ),
      ));
      await tester.tap(find.text('Open cookie login'));
      await tester.pumpAndSettle();
      final fields =
          tester.widgetList<TvTextField>(find.byType(TvTextField)).toList();
      expect(fields, hasLength(2));
      fields[0].controller.text = 'test-person';
      fields[1].controller.text = 'test-password';
      final field = find.byType(TvTextField).last;
      final keyboard = TvTextFieldScreen(
          controller: tester.widget<TvTextField>(field).controller,
          obscureText: true);
      final locals = AppLocalizations.of(tester.element(field))!;
      await selectAction(tester, locals.ok, true);
      await tester.pump();
      expect(settings.saves, 1);

      // TvTextField opens this same keyboard screen above the pending form.
      final navigator = Navigator.of(tester.element(field));
      unawaited(
          navigator.push(MaterialPageRoute<void>(builder: (_) => keyboard)));
      await tester.pumpAndSettle();
      expect(find.byType(TvTextFieldScreen), findsOneWidget);
      if (fails) {
        saving.completeError(StateError('raw backend failure detail'));
      } else {
        saving.complete();
      }
      await tester.pumpAndSettle();
      expect(find.byType(TvTextFieldScreen), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text(locals.accountActionFailed), findsNothing);
      expect(settings.state.authenticating, isFalse);
      expect(tester.takeException(), isNull);

      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.byType(TvTextField), findsNWidgets(2));
      await selectAction(tester, locals.cancel, true);
      await tester.pumpAndSettle();
      expect(find.text('Open cookie login'), findsOneWidget);
    });
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

    testWidgets(
        '$platform cancelled pending Basic save cannot close a replacement dialog',
        (tester) async {
      final saving = Completer<void>();
      var saves = 0;
      var closed = 0;
      await showHost(tester,
          television: television,
          save: (name, value) {
            saves++;
            return saving.future;
          },
          onDialogClosed: () => closed++);
      await enterCredentials(tester, television);
      await selectAction(tester, 'Add', television);
      await tester.pump();
      expect(saves, 1);

      await selectAction(tester, 'Cancel', television);
      await tester.pumpAndSettle();
      expect(closed, 1);
      await tester.tap(find.text('Open Basic authentication'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      saving.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(closed, 1);
      expect(find.text('Outer settings route'), findsOneWidget);
      expect(find.text('Server settings route'), findsOneWidget);
      expect(saves, 1);
      expect(tester.takeException(), isNull);

      await selectAction(tester, 'Cancel', television);
      await tester.pumpAndSettle();
      expect(closed, 2);
    });

    testWidgets(
        '$platform failed Basic save shows a sanitized error and retains its form',
        (tester) async {
      final saving = Completer<void>();
      var saves = 0;
      var closed = false;
      await showHost(tester,
          television: television,
          save: (name, value) {
            saves++;
            return saves == 1 ? saving.future : Future<void>.value();
          },
          onDialogClosed: () => closed = true);
      final locals = AppLocalizations.of(
          tester.element(find.text('Server settings route')))!;
      await enterCredentials(tester, television);
      await selectAction(tester, locals.add, television);
      await tester.pump();

      saving.completeError(StateError('raw backend failure detail'));
      await tester.pumpAndSettle();
      expect(find.text(locals.accountActionFailed), findsOneWidget);
      expect(find.textContaining('raw backend failure detail'), findsNothing);
      expect(closed, isFalse);
      expect(tester.takeException(), isNull);

      await selectAction(tester, locals.ok, television);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      final fields = television
          ? tester
              .widgetList<TvTextField>(find.byType(TvTextField))
              .map((field) => field.controller.text)
          : tester
              .widgetList<TextField>(find.byType(TextField))
              .map((field) => field.controller!.text);
      expect(fields, ['test-person', 'test-päss:word']);
      expect(find.text('Server settings route'), findsOneWidget);
      await selectAction(tester, locals.add, television);
      await tester.pumpAndSettle();
      expect(saves, 2);
      expect(closed, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Server settings route'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$platform pending Basic save cannot close a newer overlay',
        (tester) async {
      final saving = Completer<void>();
      await showHost(tester,
          television: television,
          save: (name, value) => saving.future,
          onDialogClosed: () {});
      await enterCredentials(tester, television);
      await selectAction(tester, 'Add', television);
      await tester.pump();
      final host = tester.element(find.text('Server settings route'));
      unawaited(showDialog<void>(
        context: host,
        useRootNavigator: false,
        builder: (context) => AlertDialog(
          title: const Text('Newer settings overlay'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Dismiss overlay'),
            ),
          ],
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Newer settings overlay'), findsOneWidget);

      saving.complete();
      await tester.pumpAndSettle();
      expect(find.text('Newer settings overlay'), findsOneWidget);
      expect(find.text('Server settings route'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Dismiss overlay'));
      await tester.pumpAndSettle();
      expect(find.text('Newer settings overlay'), findsNothing);
      expect(find.text('Server settings route'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$platform pending Basic save ignores repeated submit',
        (tester) async {
      final saving = Completer<void>();
      var saves = 0;
      await showHost(tester, television: television, save: (name, value) {
        saves++;
        return saving.future;
      }, onDialogClosed: () {});
      await enterCredentials(tester, television);
      await selectAction(tester, 'Add', television);
      await tester.pump();
      await selectAction(tester, 'Add', television);
      await tester.pump();
      expect(saves, 1);
      saving.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Server settings route'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
