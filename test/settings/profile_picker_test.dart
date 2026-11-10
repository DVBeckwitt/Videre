import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/views/components/profile_picker.dart';
import 'package:clipious/settings/views/components/watch_sync_status.dart';
import 'package:clipious/settings/views/screens/manage_single_server.dart';
import 'package:clipious/settings/views/tv/screens/manage_single_server.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/services/watch_history.dart';
import 'package:clipious/welcome_wizard/views/screens/welcome_wizard.dart';
import 'package:clipious/welcome_wizard/views/tv/screens/welcome_wizard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_settings_cubit.dart';

class _ProfileApp extends AppCubit {
  _ProfileApp() : super(AppState(0, null, HomeLayout()));

  final switches = <String>[];
  final accountSwitches = <String>[];
  final deletions = <String>[];
  Future<void> Function()? afterProfileSwitch;
  Future<void> Function()? beforeProfileDelete;

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
  Future<void> deleteProfile(String profileId) async {
    deletions.add(profileId);
    await beforeProfileDelete?.call();
    if (db.profileId == profileId) {
      final profiles = await db.getProfiles();
      await switchProfile(profiles.firstWhere((p) => p.id != profileId).id);
    }
    await db.deleteProfile(profileId);
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
      {GlobalKey<NavigatorState>? navigatorKey,
      MotionPreference motion = MotionPreference.system}) async {
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
      value: app,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            MotionScope(preference: motion, child: child!),
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

  for (final (size, extraProfiles) in [
    (const Size(320, 480), 6),
    (const Size(720, 360), 6),
    (const Size(720, 360), 1),
  ]) {
    for (final motion in [MotionPreference.system, MotionPreference.reduced]) {
      testWidgets(
          'focused profile and its controls stay visible at $size, $motion, $extraProfiles extra profiles',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        if (size.width == 720) {
          tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
          tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.view.resetViewPadding);
        }
        final active = (await tester.runAsync(() async {
          var profile = await db.createProfile(
              extraProfiles == 1 ? 'CodexProfileNativeC_1627' : 'Person 1');
          for (var index = 2; index <= extraProfiles; index++) {
            profile = await db.createProfile('Person $index');
          }
          await db.useProfile(profile.id);
          return profile;
        }))!;
        await openPicker(tester, motion: motion);
        final row = find.byKey(ValueKey('profile-${active.id}'));
        final viewport = find.descendant(
            of: find.byType(ProfilePicker),
            matching: find.byType(SingleChildScrollView));
        final scrolling = tester.state<ScrollableState>(
            find.descendant(of: viewport, matching: find.byType(Scrollable)));
        void expectReadable() {
          final bounds = tester.getRect(viewport);
          for (final target in [
            row,
            find.descendant(of: row, matching: find.text(active.name)),
            find.descendant(
                of: row, matching: find.byTooltip('Rename profile')),
            find.byKey(ValueKey('delete-profile-${active.id}')),
          ]) {
            final rect = tester.getRect(target);
            expect(rect.top, greaterThanOrEqualTo(bounds.top - 0.5));
            expect(rect.bottom, lessThanOrEqualTo(bounds.bottom + 0.5));
          }
        }

        // Initial autofocus must reveal the selected person after async loading.
        expect(
            Focus.of(tester.element(find.text(active.name))).hasFocus, isTrue);
        expectReadable();
        for (final control in [
          find.descendant(of: row, matching: find.byTooltip('Rename profile')),
          find.byKey(ValueKey('delete-profile-${active.id}')),
        ]) {
          // Moving among controls leaves the row's subtree focused. Each
          // control must still reveal the person's full row, not only its icon.
          scrolling.position.jumpTo(0);
          await tester.pump();
          final icon =
              find.descendant(of: control, matching: find.byType(Icon));
          Focus.of(tester.element(icon)).requestFocus();
          await settle(tester);
          expectReadable();
        }
        expect(db.profileId, active.id);
        expect(app.switches, isEmpty);
        expect(app.deletions, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }

  Future<void> openWelcome(WidgetTester tester, bool tv,
      {GlobalKey<NavigatorState>? navigatorKey}) async {
    final settings = TestSettingsCubit(SettingsState.init(), app);
    addTearDown(settings.close);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
      ],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: tv ? const TvWelcomeWizardScreen() : const WelcomeWizardScreen(),
      ),
    ));
    await settle(tester);
  }

  Future<void> openWelcomeProfiles(WidgetTester tester, bool tv) async {
    final entry = find.byKey(const ValueKey('welcome-profiles'));
    expect(entry, findsOneWidget);
    await tester.ensureVisible(entry);
    if (tv) {
      final label = find.descendant(of: entry, matching: find.text('Profiles'));
      Focus.of(tester.element(label)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
    } else {
      await tester.tap(entry);
    }
    await settle(tester);
    expect(find.byType(ProfilePicker), findsOneWidget);
  }

  for (final tv in [false, true]) {
    testWidgets('profiles remain usable with a soft keyboard, TV=$tv',
        (tester) async {
      tester.view.physicalSize = const Size(720, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await openWelcome(tester, tv);
      await openWelcomeProfiles(tester, tv);
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      await settle(tester);
      expect(tester.takeException(), isNull);
      final add = find.text('Add profile');
      expect(add.hitTestable(), findsOneWidget);
      await tester.tap(add);
      await settle(tester);
      expect(find.byKey(const ValueKey('profile-name-input')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Welcome exposes profiles before any server exists, TV=$tv',
        (tester) async {
      if (!tv) {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.8;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      }
      await openWelcome(tester, tv);
      await openWelcomeProfiles(tester, tv);
      expect(find.text('Add profile'), findsOneWidget);
      expect(find.byTooltip('Rename profile'), findsOneWidget);
      expect(
          tester
              .widget<IconButton>(
                  find.byKey(const ValueKey('delete-profile-default')))
              .onPressed,
          isNull);
      expect(await tester.runAsync(() => db.getServers()), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'empty-profile Welcome can rename and return to a saved profile, TV=$tv',
        (tester) async {
      const saved = Server(
          id: 'saved', url: 'https://saved.example', authToken: 'fixture');
      final temporary = (await tester.runAsync(() async {
        await db.upsertServer(saved);
        final profile = await db.createProfile('Empty person');
        await db.useProfile(profile.id);
        return profile;
      }))!;
      final navigator = GlobalKey<NavigatorState>();
      app.afterProfileSwitch = () async {
        unawaited(navigator.currentState!.pushAndRemoveUntil(
            MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Saved library'))),
            (_) => false));
      };
      await openWelcome(tester, tv, navigatorKey: navigator);
      await openWelcomeProfiles(tester, tv);
      final row = find.byKey(ValueKey('profile-${temporary.id}'));
      await tester.tap(
          find.descendant(of: row, matching: find.byTooltip('Rename profile')));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('profile-name-input')),
          'Renamed empty person');
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(find.text('Renamed empty person'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('profile-default')));
      await settle(tester);
      expect(db.profileId, 'default');
      expect(find.text('Saved library'), findsOneWidget);
      expect(
          (await tester.runAsync(() => db.getCurrentlySelectedServer()))!
              .authToken,
          'fixture');
      expect((await tester.runAsync(() => db.getProfiles()))!, hasLength(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'empty-profile Welcome permits confirmed deletion without adding a server, TV=$tv',
        (tester) async {
      final temporary = (await tester.runAsync(() async {
        final profile = await db.createProfile('Empty person');
        await db.useProfile(profile.id);
        return profile;
      }))!;
      await openWelcome(tester, tv);
      await openWelcomeProfiles(tester, tv);
      final delete = find.byKey(ValueKey('delete-profile-${temporary.id}'));
      await tester.tap(delete);
      await settle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
      await settle(tester);
      expect(db.profileId, temporary.id);
      expect(app.deletions, isEmpty);
      await tester.tap(delete);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('confirm-delete-profile')));
      await settle(tester);
      expect(app.deletions, [temporary.id]);
      expect(db.profileId, 'default');
      expect((await tester.runAsync(() => db.getProfiles()))!.single.id,
          'default');
      expect(await tester.runAsync(() => db.getServers()), isEmpty);
      expect(tester.takeException(), isNull);
    });
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

  testWidgets('rename sorting preserves the focused profile action subtree',
      (tester) async {
    final renamed = (await tester.runAsync(() async {
      await db.createProfile('B person');
      return db.createProfile('Z person');
    }))!;
    await openPicker(tester);
    final row = find.byKey(ValueKey('profile-${renamed.id}'));
    final edit =
        find.descendant(of: row, matching: find.byTooltip('Rename profile'));
    final icon = find.descendant(of: edit, matching: find.byType(Icon));
    final focus = Focus.of(tester.element(icon));
    focus.requestFocus();
    await settle(tester);
    await tester.tap(edit);
    await settle(tester);
    await tester.enterText(
        find.byKey(const ValueKey('profile-name-input')), 'A person');
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(Focus.of(tester.element(icon)), same(focus));
    expect(
        tester
            .widgetList<ListTile>(find.descendant(
                of: find.byType(ProfilePicker),
                matching: find.byType(ListTile)))
            .map((tile) => (tile.title! as Text).data),
        ['Default', 'A person', 'B person']);
    expect(app.switches, isEmpty);
    expect(app.deletions, isEmpty);
  });

  testWidgets('the last profile cannot be deleted and explains how to proceed',
      (tester) async {
    await openPicker(tester);
    final delete = find.byKey(const ValueKey('delete-profile-default'));
    expect(tester.widget<IconButton>(delete).onPressed, isNull);
    expect(find.textContaining('At least one profile is required'),
        findsOneWidget);
    expect(find.text('Add profile'), findsOneWidget);
    expect(find.byTooltip('Rename profile'), findsOneWidget);
  });

  testWidgets('deleting an inactive profile requires explicit confirmation',
      (tester) async {
    final second =
        (await tester.runAsync(() => db.createProfile('Second person')))!;
    await openPicker(tester);
    await tester.tap(find.byKey(ValueKey('delete-profile-${second.id}')));
    await settle(tester);
    expect(find.textContaining('Delete "Second person"?'), findsOneWidget);
    expect(find.textContaining('Downloaded files are kept'), findsOneWidget);
    expect(app.deletions, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
    await settle(tester);
    expect((await tester.runAsync(() => db.getProfiles()))!, hasLength(2));
    expect(app.deletions, isEmpty);

    await tester.tap(find.byKey(ValueKey('delete-profile-${second.id}')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('confirm-delete-profile')));
    await settle(tester);
    expect(app.deletions, [second.id]);
    expect(app.switches, isEmpty);
    expect(db.profileId, 'default');
    expect(find.text('Second person'), findsNothing);
    expect(
        (await tester.runAsync(() => db.getProfiles()))!.single.id, 'default');
  });

  testWidgets('deleting the active profile leaves the replacement page open',
      (tester) async {
    final second =
        (await tester.runAsync(() => db.createProfile('Second person')))!;
    final navigator = GlobalKey<NavigatorState>();
    app.afterProfileSwitch = () async {
      unawaited(navigator.currentState!.pushAndRemoveUntil(
          MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Remaining library'))),
          (_) => false));
    };
    await openPicker(tester, navigatorKey: navigator);
    await tester.tap(find.byKey(const ValueKey('delete-profile-default')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('confirm-delete-profile')));
    await settle(tester);
    expect(app.deletions, ['default']);
    expect(db.profileId, second.id);
    expect(
        (await tester.runAsync(() => db.getProfiles()))!.single.id, second.id);
    expect(find.text('Remaining library'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('deletion stays busy and a failure leaves a retryable profile',
      (tester) async {
    final second =
        (await tester.runAsync(() => db.createProfile('Second person')))!;
    final pending = Completer<void>();
    app.beforeProfileDelete = () => pending.future;
    await openPicker(tester);
    await tester.tap(find.byKey(ValueKey('delete-profile-${second.id}')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('confirm-delete-profile')));
    await settle(tester);
    expect(
        tester
            .widget<IconButton>(
                find.byKey(ValueKey('delete-profile-${second.id}')))
            .onPressed,
        isNull);
    expect(app.deletions, [second.id]);
    pending.completeError(StateError('Private cleanup detail'));
    await settle(tester);
    expect(find.text('Could not update the profile. Please try again.'),
        findsOneWidget);
    expect(find.textContaining('Private cleanup detail'), findsNothing);
    expect((await tester.runAsync(() => db.getProfiles()))!, hasLength(2));
    expect(
        tester
            .widget<IconButton>(
                find.byKey(ValueKey('delete-profile-${second.id}')))
            .onPressed,
        isNotNull);
  });

  testWidgets('deletion failure after navigation is visible on the new page',
      (tester) async {
    await tester.runAsync(() => db.createProfile('Second person'));
    final navigator = GlobalKey<NavigatorState>();
    app.afterProfileSwitch = () async {
      unawaited(navigator.currentState!.pushAndRemoveUntil(
          MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Remaining library'))),
          (_) => false));
      // The old picker is still mounted for its outgoing route animation.
      throw StateError('Private native cleanup failure');
    };
    await openPicker(tester, navigatorKey: navigator);
    await tester.tap(find.byKey(const ValueKey('delete-profile-default')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('confirm-delete-profile')));
    await settle(tester);
    expect(find.text('Remaining library'), findsOneWidget);
    expect(find.text('Could not update the profile. Please try again.'),
        findsOneWidget);
    expect(find.textContaining('Private native cleanup failure'), findsNothing);
    expect((await tester.runAsync(() => db.getProfiles()))!, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('delete confirmation fits large text and accepts TV Select',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final second = (await tester.runAsync(
        () => db.createProfile('Another person with a long display name')))!;
    await openPicker(tester);
    final delete = find.byKey(ValueKey('delete-profile-${second.id}'));
    await tester.ensureVisible(delete);
    await tester.tap(delete);
    await settle(tester);
    final confirm = find.byKey(const ValueKey('confirm-delete-profile'));
    await tester.ensureVisible(confirm);
    final label = find.descendant(of: confirm, matching: find.byType(Text));
    Focus.of(tester.element(label)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await settle(tester);
    expect(app.deletions, [second.id]);
    expect(tester.takeException(), isNull);
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
