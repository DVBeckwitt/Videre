import 'dart:io';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as application;
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/views/tv/screens/settings.dart'
    as tv_settings;
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_settings_cubit.dart';

class _App extends Cubit<AppState> implements AppCubit {
  _App() : super(AppState(0, null, HomeLayout()));

  @override
  Future<void> initState() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _IdlePlayer extends Cubit<PlayerState> implements PlayerCubit {
  _IdlePlayer() : super(PlayerState.init(null));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RestoreSettings extends TestSettingsCubit {
  _RestoreSettings(super.initialState, super.appCubit);

  late Future<void> backupOperation;

  @override
  Future<void> backupLibrary(BuildContext context, {bool restore = false}) =>
      backupOperation = super.backupLibrary(context, restore: restore);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const files = MethodChannel('videre/files');
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory documents;
  late _App app;
  late _IdlePlayer player;
  late _RestoreSettings settings;
  late DownloadManagerCubit downloads;
  late String backupText;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('videre-restore-test-');
    db = await SembastSqfDb.createInMemory();
    app = _App();
    player = _IdlePlayer();
    settings = _RestoreSettings(SettingsState.init(), app);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(files, null);
    messenger.setMockMethodCallHandler(pathProvider, null);
    await downloads.close();
    await settings.close();
    await player.close();
    await app.close();
    await db.close();
    await documents.delete(recursive: true);
  });

  for (final tv in [false, true]) {
    testWidgets('Welcome can skip or restore Music before setup, TV=$tv',
        (tester) async {
      final previousTv = application.isTv;
      application.isTv = tv;
      addTearDown(() => application.isTv = previousTv);
      final router = AppRouter(hasServer: false);
      addTearDown(router.dispose);
      const song = MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'abcdefghijk',
        title: 'Restored song',
      );
      final library = MusicLibraryService.forProfile(db, db.profileId);
      await tester.runAsync(() async {
        final source = await SembastSqfDb.createInMemory();
        await MusicLibraryService.forProfile(source, source.profileId)
            .save(song);
        backupText = (await source.exportBackup()).encode();
        await source.close();
        downloads = DownloadManagerCubit(const DownloadManagerState(), player);
      });
      String? pickedText;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(files, (call) async {
        calls.add(call.method);
        return pickedText;
      });
      messenger.setMockMethodCallHandler(
          pathProvider, (call) async => documents.path);
      await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<AppCubit>.value(value: app),
          BlocProvider<SettingsCubit>.value(value: settings),
          BlocProvider<PlayerCubit>.value(value: player),
          BlocProvider<DownloadManagerCubit>.value(value: downloads),
        ],
        child: MaterialApp.router(
          routerConfig: router.config(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ));
      await tester.pumpAndSettle();

      if (tv) {
        final setup = find.descendant(
          of: find.widgetWithText(tv_settings.SettingsTile, 'Add server'),
          matching: find.byType(ListTile),
        );
        final focus = Focus.of(tester.element(setup));
        focus.requestFocus();
        await tester.pump();
        expect(focus.hasPrimaryFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
      } else {
        await tester.tap(find.text('Enter an instance address'));
      }
      await tester.pumpAndSettle();
      expect(router.current.name,
          tv ? TvAddServerRoute.name : AddServerRoute.name);
      expect(calls, isEmpty);
      expect(library.entries, isEmpty);
      expect(await router.maybePop(), isTrue);
      await tester.pumpAndSettle();

      tester.view.physicalSize =
          tv ? const Size(720, 360) : const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (!tv) {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      }
      await tester.pumpAndSettle();
      final entry = find.text('Restore library backup');
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      expect(entry.hitTestable(), findsOneWidget);
      expect(
          tester.getSemantics(entry).getSemanticsData().hasAction(
                SemanticsAction.tap,
              ),
          isTrue);

      Future<void> openRestore() async {
        if (tv) {
          final profiles = find.descendant(
            of: find.byKey(const ValueKey('welcome-profiles')),
            matching: find.text('Profiles'),
          );
          Focus.of(tester.element(profiles)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pumpAndSettle();
          expect(Focus.of(tester.element(entry)).hasFocus, isTrue);
          await tester
              .runAsync(() => tester.sendKeyEvent(LogicalKeyboardKey.select));
        } else {
          await tester.runAsync(() => tester.tap(entry));
        }
        await tester.pumpAndSettle();
      }

      await openRestore();
      await tester.runAsync(() => settings.backupOperation);
      expect(find.byType(AlertDialog), findsNothing);
      expect(library.entries, isEmpty);

      pickedText = 'invalid backup';
      await openRestore();
      expect(find.text('Error'), findsOneWidget);
      expect(find.text('Merge'), findsNothing);
      expect(library.entries, isEmpty);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      pickedText = backupText;
      await openRestore();
      expect(find.textContaining('1 entries ready'), findsOneWidget);
      expect(library.entries, isEmpty);
      final cancel = find.text('Cancel');
      expect(cancel.hitTestable(), findsOneWidget);
      await tester.tap(cancel);
      await tester.pump();
      await tester.runAsync(() => settings.backupOperation);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(library.entries, isEmpty);

      await openRestore();
      final merge = find.text('Merge');
      if (tv) {
        Focus.of(tester.element(merge)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
      } else {
        await tester.tap(merge);
      }
      await tester.pump();
      await tester.runAsync(() => settings.backupOperation);
      await tester.pumpAndSettle();
      expect(calls, List.filled(4, 'open'));
      expect(library.entries.single.id, song.id);
      expect(await tester.runAsync(() => db.getServers()), isEmpty);
      expect(entry, findsOneWidget);
      expect(find.textContaining('Library restored.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final scenario in [
    (existing: false, imported: true, replace: true, expected: true),
    (existing: true, imported: false, replace: true, expected: false),
    (existing: false, imported: true, replace: false, expected: false),
  ]) {
    testWidgets(
        'restore immediately applies effective Wi-Fi preference $scenario',
        (tester) async {
      await tester.runAsync(() async {
        final source = await SembastSqfDb.createInMemory();
        await source.saveSetting(
            SettingsValue('downloads-wifi-only', '${scenario.imported}'));
        backupText = (await source.exportBackup()).encode();
        await source.close();
        await db.saveSetting(
            SettingsValue('downloads-wifi-only', '${scenario.existing}'));
        downloads = DownloadManagerCubit(const DownloadManagerState(), player);
        await downloads.setWifiOnly(scenario.existing);
      });
      messenger.setMockMethodCallHandler(files, (call) async => backupText);
      messenger.setMockMethodCallHandler(
          pathProvider, (call) async => documents.path);
      await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<PlayerCubit>.value(value: player),
          BlocProvider<DownloadManagerCubit>.value(value: downloads),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
              body: Builder(
                  builder: (context) => TextButton(
                        onPressed: () =>
                            settings.backupLibrary(context, restore: true),
                        child: const Text('Restore'),
                      ))),
        ),
      ));
      // Keep the restore's file and database continuations on the real clock.
      await tester.runAsync(() async {
        await tester.tap(find.text('Restore'));
      });
      await tester.pumpAndSettle();
      await tester
          .tap(find.text(scenario.replace ? 'Replace local data' : 'Merge'));
      await tester.pump();
      await tester.runAsync(() => settings.backupOperation);
      await tester.pumpAndSettle();
      expect(downloads.state.wifiOnly, scenario.expected);
      expect(downloads.state.waitingForWifi, scenario.expected);
      expect(
          db.getSettings('downloads-wifi-only')?.value, '${scenario.expected}');
      expect(settings.state.settings['downloads-wifi-only']?.value,
          '${scenario.expected}');
      expect(
          find.text('Library restored. Reopen Videre to refresh all screens.'),
          findsOneWidget);
    });
  }
}
