import 'dart:async';
import 'dart:io';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/add_server.dart';
import 'package:clipious/settings/states/server_settings.dart';
import 'package:clipious/settings/views/components/nerdvpn_access_settings.dart';
import 'package:clipious/settings/views/screens/add_server.dart';
import 'package:clipious/settings/views/screens/manage_single_server.dart';
import 'package:clipious/settings/views/tv/screens/add_server.dart';
import 'package:clipious/settings/views/tv/screens/manage_single_server.dart';
import 'package:clipious/settings/views/tv/screens/settings.dart' as tv;
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/views/tv/components/tv_text_field.dart';
import 'package:clipious/utils/views/tv/components/tv_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:settings_ui/settings_ui.dart' as phone;

const _access = MethodChannel('videre/nerdvpn_access');
const _account =
    Server(id: 'nerdvpn-account', url: 'https://invidious.nerdvpn.de');
const _manualKey = 'nvpn_0123456789abcdefghijklmnopqrstuv';

class _SettingsApp extends AppCubit {
  _SettingsApp() : super(AppState(0, null, HomeLayout()));

  @override
  void onReady() {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  void initState() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var nativeStatus = <String, Object?>{};
  final calls = <String>[];

  setUp(() {
    nativeStatus = {'state': 'ready'};
    calls.clear();
    messenger.setMockMethodCallHandler(_access, (call) async {
      calls.add(call.method);
      return nativeStatus;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(_access, null));

  Future<void> showPanel(WidgetTester tester,
      {Future<void> Function()? onCheck,
      Future<void> Function(String)? onSaveKey,
      bool authenticating = false}) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: NerdVpnAccessSettings(
            account: _account,
            authenticating: authenticating,
            onCheck: onCheck ?? () async {},
            onSaveKey: onSaveKey ?? (_) async {},
          ),
        ),
      ),
    ));
    if (authenticating) {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    } else {
      await tester.pumpAndSettle();
    }
  }

  Future<void> showManager(WidgetTester tester,
      {required bool television, Server account = _account}) async {
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final documents = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('videre-nerdvpn-settings-')))!;
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documents.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(pathProvider, null);
      await documents.delete(recursive: true);
    });
    db = (await tester.runAsync(() => SembastSqfDb.createInMemory()))!;
    await tester.runAsync(() => db.upsertServer(account));
    final app = _SettingsApp();
    addTearDown(() async {
      await app.close();
      await db.close();
    });
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
      value: app,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: television
            ? TvManageSingleServerScreen(server: account)
            : ManageSingleServerScreen(server: account),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'waiting state displays the server date and offers an explicit eligibility check',
      (tester) async {
    final availableAt = DateTime.utc(2031, 2, 18, 9, 30);
    nativeStatus = {
      'state': 'waiting',
      'availableAt': availableAt.toIso8601String(),
    };
    var checks = 0;
    await showPanel(tester, onCheck: () async {
      checks++;
      nativeStatus = {'state': 'ready'};
    });

    final displayDate =
        DateFormat.yMMMd('en').add_jm().format(availableAt.toLocal());
    expect(find.textContaining(displayDate), findsOneWidget);
    expect(find.text('Check eligibility'), findsOneWidget);
    final locals = AppLocalizations.of(
        tester.element(find.byType(NerdVpnAccessSettings)))!;
    expect(find.text(locals.chooseInstance), findsOneWidget);
    expect(checks, 0);
    await tester.tap(find.text('Check eligibility'));
    await tester.pumpAndSettle();
    expect(checks, 1);
    expect(find.text('An API key is saved securely for this account.'),
        findsOneWidget);
  });

  testWidgets(
      'disabled access waits for Check again and coalesces a pending UI action',
      (tester) async {
    nativeStatus = {'state': 'disabled'};
    final checked = Completer<void>();
    var checks = 0;
    await showPanel(tester, onCheck: () {
      checks++;
      return checked.future;
    });

    expect(find.textContaining('turned off in your NerdVPN preferences'),
        findsOneWidget);
    await tester.pump(const Duration(minutes: 1));
    expect(checks, 0);
    expect(calls, ['status']);
    await tester.tap(find.text('Check again'));
    await tester.pump();
    final button = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Check again'));
    expect(button.onPressed, isNull);
    expect(checks, 1);
    checked.complete();
    await tester.pumpAndSettle();
    expect(checks, 1);
    expect(calls, ['status', 'status']);
  });

  testWidgets('manual key entry is obscured and validates before saving',
      (tester) async {
    final saved = <String>[];
    await showPanel(tester, onSaveKey: (key) async => saved.add(key));
    await tester.tap(find.text('Enter API key'));
    await tester.pumpAndSettle();
    final input = find.byType(TextField);
    expect(tester.widget<TextField>(input).obscureText, isTrue);
    expect(tester.widget<TextField>(input).enableSuggestions, isFalse);
    await tester.enterText(input, 'invalid-key');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
    expect(find.textContaining('32 letters or digits'), findsOneWidget);

    await tester.enterText(input, _manualKey);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(saved, [_manualKey]);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(_manualKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'failed access checks show a generic message without exception details',
      (tester) async {
    await showPanel(tester, onCheck: () async {
      throw StateError('private-token $_manualKey');
    });
    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();
    expect(find.textContaining('private-token'), findsNothing);
    expect(find.text(_manualKey), findsNothing);
    final locals = AppLocalizations.of(
        tester.element(find.byType(NerdVpnAccessSettings)))!;
    expect(find.text(locals.accountActionFailed), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an active sign-in disables access actions', (tester) async {
    await showPanel(tester, authenticating: true);
    for (final button
        in tester.widgetList<TextButton>(find.byType(TextButton))) {
      expect(button.onPressed, isNull);
    }
  });

  for (final television in [false, true]) {
    testWidgets(
        '${television ? 'TV' : 'phone'} manual-key-only account can clear its key without deleting the account',
        (tester) async {
      const gatewaySessions = MethodChannel('videre/gateway_sessions');
      messenger.setMockMethodCallHandler(
          gatewaySessions, (_) async => {'supported': true, 'enabled': false});
      addTearDown(
          () => messenger.setMockMethodCallHandler(gatewaySessions, null));
      messenger.setMockMethodCallHandler(_access, (call) async {
        calls.add(call.method);
        if (call.method == 'clear') nativeStatus = {'state': 'missing'};
        return nativeStatus;
      });
      await showManager(tester, television: television);
      final panel = tester.element(find.byType(NerdVpnAccessSettings));
      final locals = AppLocalizations.of(panel)!;
      expect(find.text(locals.nerdVpnAccessReady), findsOneWidget);
      final logout = find.text(locals.logout);
      if (television) {
        expect(
            tester
                .widget<tv.SettingsTile>(find.ancestor(
                    of: logout, matching: find.byType(tv.SettingsTile)))
                .enabled,
            isTrue);
      } else {
        expect(
            tester
                .widget<phone.SettingsTile>(find.ancestor(
                    of: logout, matching: find.byType(phone.SettingsTile)))
                .enabled,
            isTrue);
      }
      await tester.runAsync(() => panel.read<ServerSettingsCubit>().logOut());
      await tester.pumpAndSettle();
      expect(calls.where((method) => method == 'clear'), hasLength(1));
      expect(calls, isNot(contains('setKey')));
      expect(nativeStatus['state'], 'missing');
      final saved = db.getAccount(_account.accountId);
      expect(saved, isNotNull);
      expect(saved!.authToken, isNull);
      expect(saved.sidCookie, isNull);
      expect(saved.customHeaders, isEmpty);
      expect(find.text(locals.nerdVpnAccessReady), findsNothing);
      expect(find.text(locals.nerdVpnAccessSignIn), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '${television ? 'TV' : 'phone'} unsigned generic account still disables logout',
        (tester) async {
      await showManager(tester,
          television: television,
          account: const Server(id: 'generic', url: 'https://other.example'));
      final logout = find.text('Log out');
      if (television) {
        expect(
            tester
                .widget<tv.SettingsTile>(find.ancestor(
                    of: logout, matching: find.byType(tv.SettingsTile)))
                .enabled,
            isFalse);
      } else {
        expect(
            tester
                .widget<phone.SettingsTile>(find.ancestor(
                    of: logout, matching: find.byType(phone.SettingsTile)))
                .enabled,
            isFalse);
      }
      expect(calls, isEmpty);
    });

    testWidgets(
        '${television ? 'TV' : 'phone'} generic key header validates and safely reports storage failure',
        (tester) async {
      await showManager(tester, television: television);
      final panel = tester.element(find.byType(NerdVpnAccessSettings));
      final locals = AppLocalizations.of(panel)!;
      if (television) {
        tester
            .widget<TvManageSingleServerScreen>(
                find.byType(TvManageSingleServerScreen))
            .showAddHeaderDialog(panel);
      } else {
        tester
            .widget<ManageSingleServerScreen>(
                find.byType(ManageSingleServerScreen))
            .showAddHeaderDialog(panel);
      }
      await tester.pumpAndSettle();
      final inputs = find.byType(TextField);
      Future<void> activate(String label) async {
        if (television) {
          final button = find.ancestor(
              of: find.text(label).last, matching: find.byType(TvButton));
          tester.widget<TvButton>(button).onPressed!(tester.element(button));
        } else {
          await tester.tap(find.text(label).last);
        }
      }

      Future<void> enterHeader(String key, String value) async {
        if (television) {
          final fields =
              tester.widgetList<TvTextField>(find.byType(TvTextField)).toList();
          fields[0].controller.text = key;
          fields[1].controller.text = value;
        } else {
          await tester.enterText(inputs.at(0), key);
          await tester.enterText(inputs.at(1), value);
        }
      }

      await enterHeader('X-Invidious-Token', 'invalid-key');
      await activate(locals.add);
      await tester.pumpAndSettle();
      expect(find.text(locals.nerdVpnKeyInvalid), findsOneWidget);
      expect(calls, isNot(contains('setKey')));
      expect(tester.takeException(), isNull);
      await activate(locals.ok);
      await tester.pumpAndSettle();

      messenger.setMockMethodCallHandler(_access, (call) async {
        calls.add(call.method);
        if (call.method == 'setKey') {
          throw PlatformException(
              code: 'SECURE_STORAGE_UNAVAILABLE', message: _manualKey);
        }
        return nativeStatus;
      });
      await enterHeader('X-Invidious-Token', _manualKey);
      await activate(locals.add);
      await tester.pumpAndSettle();
      expect(find.textContaining('temporarily unavailable'), findsOneWidget);
      expect(calls.where((method) => method == 'setKey'), hasLength(1));
      expect(tester.takeException(), isNull);
      await activate(locals.ok);
      await tester.pumpAndSettle();
      expect(
          find.byType(television ? TvTextField : TextField), findsNWidgets(2));
      expect(db.getAccount(_account.accountId)!.customHeaders, isEmpty);
    });

    testWidgets(
        '${television ? 'TV' : 'phone'} typed URL updates NerdVPN guidance while validity stays true',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      db = (await tester.runAsync(() => SembastSqfDb.createInMemory()))!;
      addTearDown(() => db.close());
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: television ? const TvAddServerScreen() : const AddServerScreen(),
      ));
      await tester.pumpAndSettle();
      final formContext = tester.element(find.byType(FilledButton));
      final cubit = formContext.read<AddServerCubit>();
      final locals = AppLocalizations.of(formContext)!;

      Future<void> enterUrl(String value) async {
        if (television) {
          // The TV keyboard route edits the same controller held by the form.
          cubit.urlController.text = value;
        } else {
          await tester.enterText(find.byType(TextField).first, value);
        }
        await tester.pumpAndSettle();
      }

      await enterUrl('https://other.example');
      expect(cubit.state.valid, isTrue);
      expect(find.text(locals.instanceAddressDescription), findsOneWidget);
      expect(find.text(locals.testAndAddServer), findsOneWidget);
      final validState = cubit.state;

      await enterUrl('https://invidious.nerdvpn.de');
      expect(identical(cubit.state, validState), isTrue);
      expect(find.text(locals.nerdVpnAccessSignIn), findsOneWidget);
      expect(find.text(locals.nerdVpnSignInAndAdd), findsOneWidget);
      expect(find.text(locals.instanceAddressDescription), findsNothing);

      await cubit.addHeader('X-Invidious-Token', _manualKey);
      await tester.pumpAndSettle();
      expect(find.text(locals.testAndAddServer), findsOneWidget);
      expect(find.text(locals.nerdVpnSignInAndAdd), findsNothing);
      cubit.removeHeader('X-Invidious-Token');
      await tester.pumpAndSettle();
      expect(find.text(locals.nerdVpnSignInAndAdd), findsOneWidget);

      await enterUrl('https://different.example');
      expect(cubit.state.valid, isTrue);
      expect(find.text(locals.instanceAddressDescription), findsOneWidget);
      expect(find.text(locals.testAndAddServer), findsOneWidget);
      expect(find.text(locals.nerdVpnAccessSignIn), findsNothing);
      expect(calls, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '${television ? 'TV' : 'phone'} NerdVPN settings disable cookies and mask legacy key headers',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      db = (await tester.runAsync(() => SembastSqfDb.createInMemory()))!;
      final account = _account.copyWith(
        authToken: 'existing-account-token',
        customHeaders: {'X-Invidious-Token': _manualKey},
      );
      await tester.runAsync(() => db.upsertServer(account));
      final app = _SettingsApp();
      addTearDown(() async {
        await app.close();
        await db.close();
      });
      await tester.pumpWidget(BlocProvider<AppCubit>.value(
        value: app,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: television
              ? TvManageSingleServerScreen(server: account)
              : ManageSingleServerScreen(server: account),
        ),
      ));
      await tester.pumpAndSettle();

      final cookie = find.text('Log in with cookie');
      if (television) {
        final tile = tester.widget<tv.SettingsTile>(
            find.ancestor(of: cookie, matching: find.byType(tv.SettingsTile)));
        expect(tile.enabled, isFalse);
      } else {
        final tile = tester.widget<phone.SettingsTile>(find.ancestor(
            of: cookie, matching: find.byType(phone.SettingsTile)));
        expect(tile.enabled, isFalse);
        final token = tester.widget<phone.SettingsTile>(find.ancestor(
            of: find.text('Log in with token'),
            matching: find.byType(phone.SettingsTile)));
        expect(token.enabled, isTrue);
      }
      expect(find.text(_manualKey), findsNothing);
      expect(find.text('········'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
