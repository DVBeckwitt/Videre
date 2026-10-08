import 'dart:io';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const files = MethodChannel('videre/files');
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory documents;
  late _App app;
  late _IdlePlayer player;
  late TestSettingsCubit settings;
  late DownloadManagerCubit downloads;
  late String backupText;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('videre-restore-test-');
    db = await SembastSqfDb.createInMemory();
    app = _App();
    player = _IdlePlayer();
    settings = TestSettingsCubit(SettingsState.init(), app);
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
      late Future<void> restoring;
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
                        onPressed: () {
                          restoring =
                              settings.backupLibrary(context, restore: true);
                        },
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
      await tester.runAsync(() => restoring);
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
