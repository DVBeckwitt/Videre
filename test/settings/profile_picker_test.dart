import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/views/components/profile_picker.dart';
import 'package:clipious/settings/views/components/watch_sync_status.dart';
import 'package:clipious/settings/views/screens/manage_single_server.dart';
import 'package:clipious/settings/views/tv/screens/manage_single_server.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/services/watch_history.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _ProfileApp extends AppCubit {
  _ProfileApp() : super(AppState(0, null, HomeLayout()));

  final switches = <String>[];
  final accountSwitches = <String>[];
  Future<void> Function()? afterProfileSwitch;

  @override
  void onReady() {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  void initState() {}

  @override
  Future<void> switchProfile(String profileId) async {
    switches.add(profileId);
    await db.useProfile(profileId);
    await afterProfileSwitch?.call();
  }

  @override
  Future<Server?> switchServer(Server server) async {
    accountSwitches.add(server.accountId);
    await db.useServer(server);
    return server;
  }
}

class _WatchSyncService extends Service {
  final accounts = <Server>[];
  final forceValues = <bool>[];

  @override
  Future<void> syncAccountHistory(Server account,
      {IDbClient? database, bool force = false, bool pull = true}) async {
    accounts.add(account);
    forceValues.add(force);
    expect(database!.profileId, account.profileId);
    await WatchRepository.forDatabase(database)!
        .setSyncStatus(account.accountId, 'synced');
  }
}

class _FailingAccountService extends Service {
  final Future<Server?>? cookieResult;
  _FailingAccountService({this.cookieResult});

  @override
  Future<Server?> logInProtected(Server original) async =>
      throw StateError('Sensitive authentication response');

  @override
  Future<String?> logIn(String accountId, {String? profileId}) async =>
      throw StateError('Sensitive authentication response');

  @override
  Future<Server?> logOutProtected(Server server) async =>
      throw StateError('Sensitive authentication response');

  @override
  Future<Server?> logInAccountWithCookie(
      Server original, String username, String password) async {
    if (cookieResult != null) return cookieResult;
    throw StateError('Sensitive authentication response');
  }
}

void main() {
  late _ProfileApp app;
  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = _ProfileApp();
  });

  tearDown(() async {
    await app.close();
    await db.close();
  });

  Future<void> openPicker(WidgetTester tester,
      {GlobalKey<NavigatorState>? navigatorKey}) async {
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
      value: app,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
            builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => showProfilePicker(context),
                      child: const Text('Open profiles')),
                )),
      ),
    ));
    await tester.tap(find.text('Open profiles'));
    await settle(tester);
  }

  testWidgets('picker switches people by ID and closes', (tester) async {
    final second =
        (await tester.runAsync(() => db.createProfile('Second person')))!;
    await openPicker(tester);
    expect(find.text('Default'), findsOneWidget);
    expect(find.text('Second person'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('profile-${second.id}')));
    await settle(tester);
    expect(app.switches, [second.id]);
    expect(db.profileId, second.id);
    expect(find.byType(ProfilePicker), findsNothing);
  });

  testWidgets('creating a profile trims its name and selects the empty library',
      (tester) async {
    await openPicker(tester);
    await tester.tap(find.text('Add profile'));
    await settle(tester);
    await tester.enterText(
        find.byKey(const ValueKey('profile-name-input')), '  Family  ');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await settle(tester);
    final people = (await tester.runAsync(() => db.getProfiles()))!;
    expect(people.map((p) => p.name), unorderedEquals(['Default', 'Family']));
    expect(db.profileId, people.singleWhere((p) => p.name == 'Family').id);
    expect(await tester.runAsync(() => db.getServers()), isEmpty);
  });

  testWidgets('profile navigation reset does not pop the new page',
      (tester) async {
    final second =
        (await tester.runAsync(() => db.createProfile('Second person')))!;
    final navigator = GlobalKey<NavigatorState>();
    app.afterProfileSwitch = () async {
      unawaited(navigator.currentState!.pushAndRemoveUntil(
          MaterialPageRoute<void>(
              builder: (_) =>
                  const Scaffold(body: Text('New profile library'))),
          (_) => false));
    };
    await openPicker(tester, navigatorKey: navigator);
    await tester.tap(find.byKey(ValueKey('profile-${second.id}')));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('New profile library'), findsOneWidget);
    expect(find.byType(ProfilePicker), findsNothing);
  });

  testWidgets('same-server accounts remain separately selectable',
      (tester) async {
    const first =
        Server(id: 'first', name: 'Alice', url: 'https://same.example');
    const second =
        Server(id: 'second', name: 'Bob', url: 'https://same.example');
    await tester.runAsync(() async {
      await db.upsertServer(first);
      await db.upsertServer(second);
    });
    await openPicker(tester);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('account-second')));
    await tester.tap(find.byKey(const ValueKey('account-second')));
    await settle(tester);
    expect(app.accountSwitches, ['second']);
    expect(
        (await tester.runAsync(() => db.getCurrentlySelectedServer()))!
            .accountId,
        'second');
  });

  testWidgets('renaming a person preserves its identity', (tester) async {
    await openPicker(tester);
    await tester.tap(find.byTooltip('Rename profile'));
    await settle(tester);
    await tester.enterText(
        find.byKey(const ValueKey('profile-name-input')), 'Me');
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(
        (await tester.runAsync(() => db.getProfiles()))!.single.id, 'default');
    expect(find.text('Me'), findsOneWidget);
    expect(app.switches, isEmpty);
  });

  testWidgets('watch sync retry keeps its original person and account',
      (tester) async {
    const account = Server(
        id: 'shared-account-id',
        url: 'https://same.example',
        authToken: 'first');
    final owner = db.forProfile('default');
    await tester.runAsync(() async {
      await owner.upsertServer(account);
      await WatchRepository.forDatabase(owner)!
          .setSyncStatus(account.accountId, 'pending');
      final second = await db.createProfile('Second');
      await db.useProfile(second.id);
      await db.upsertServer(
          account.copyWith(profileId: second.id, authToken: 'second'));
      await WatchRepository.forDatabase(db)!
          .setSyncStatus(account.accountId, 'pending');
    });
    final previousService = service;
    final sync = _WatchSyncService();
    service = sync;
    addTearDown(() => service = previousService);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: WatchSyncStatus(account: account)),
    ));
    expect(find.text('Watch status saved. Waiting to sync.'), findsOneWidget);
    await tester.tap(find.text('Retry watch status sync'));
    await settle(tester);
    expect(sync.accounts, [account.copyWith(inUse: true)]);
    expect(sync.forceValues, [true]);
    expect(
        WatchRepository.forDatabase(db)!
            .syncStatus(account.accountId)?['state'],
        'pending');
    expect(find.text('Retry watch status sync'), findsNothing);
  });

  testWidgets('watch sync asks for sign-in when credentials are absent',
      (tester) async {
    const account = Server(id: 'signed-out', url: 'https://same.example');
    await tester.runAsync(() async {
      await db.upsertServer(account);
      await WatchRepository.forDatabase(db)!
          .setSyncStatus(account.accountId, 'signInRequired');
    });
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: WatchSyncStatus(account: account)),
    ));
    expect(find.text('Sign in again to sync watch status.'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(
                find.byWidgetPredicate((widget) => widget is TextButton))
            .onPressed,
        isNull);
  });

  testWidgets('watch sync cannot retry using a deleted account replacement',
      (tester) async {
    const legacy = Server(url: 'https://same.example', authToken: 'old');
    final replacement = legacy.copyWith(id: 'replacement', authToken: 'new');
    await tester.runAsync(() async {
      await db.upsertServer(legacy);
      await db.upsertServer(replacement);
      await db.deleteServerById(legacy);
      await WatchRepository.forDatabase(db)!
          .setSyncStatus(legacy.accountId, 'pending');
    });
    final previousService = service;
    final sync = _WatchSyncService();
    service = sync;
    addTearDown(() => service = previousService);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: WatchSyncStatus(account: legacy)),
    ));

    expect(find.text('Sign in again to sync watch status.'), findsOneWidget);
    final retry = tester.widget<TextButton>(
        find.byWidgetPredicate((widget) => widget is TextButton));
    expect(retry.onPressed, isNull);
    expect(sync.accounts, isEmpty);
    expect(db.getAccount(replacement.accountId)?.authToken, 'new');
  });

  for (final tv in [false, true]) {
    for (final action in [
      'Sign in to protected server',
      if (!tv) 'Log in with token',
      'Log in with cookie',
      'Log out',
    ]) {
      testWidgets('${tv ? 'TV' : 'phone'} $action handles auth errors safely',
          (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final account = Server(
            id: 'account',
            url: 'https://same.example',
            authToken: action == 'Log out' ? 'existing-token' : null);
        await tester.runAsync(() => db.upsertServer(account));
        final previousService = service;
        service = _FailingAccountService();
        addTearDown(() => service = previousService);
        await tester.pumpWidget(BlocProvider<AppCubit>.value(
          value: app,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: tv
                ? TvManageSingleServerScreen(server: account)
                : ManageSingleServerScreen(server: account),
          ),
        ));
        await settle(tester);
        Future<void> activate(Finder target) async {
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          if (tv) {
            final focus = find.ancestor(
                of: target,
                matching: find.byWidgetPredicate(
                    (widget) => widget is Focus && widget.onKeyEvent != null));
            final child = find
                .descendant(of: focus.first, matching: find.byType(Builder))
                .first;
            Focus.of(tester.element(child)).requestFocus();
            await tester.pumpAndSettle();
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
          } else {
            await tester.tap(target);
          }
          await settle(tester);
        }

        await activate(find.text(action));
        if (action == 'Log in with cookie') {
          await activate(find.text('OK'));
        }
        expect(find.text('Could not update this account. Please try again.'),
            findsOneWidget);
        expect(find.textContaining('Sensitive authentication'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
      'cancelled cookie dialog does not pop the account page on completion',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const account = Server(id: 'account', url: 'https://same.example');
    await tester.runAsync(() => db.upsertServer(account));
    final previousService = service;
    final result = Completer<Server?>();
    service = _FailingAccountService(cookieResult: result.future);
    addTearDown(() => service = previousService);
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
      value: app,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ManageSingleServerScreen(server: account),
      ),
    ));
    await settle(tester);
    await tester.tap(find.text('Log in with cookie'));
    await settle(tester);
    await tester.tap(find.text('OK'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    result.complete(null);
    await settle(tester);
    expect(find.byType(ManageSingleServerScreen), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var attempt = 0; attempt < 8; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
  }
}
