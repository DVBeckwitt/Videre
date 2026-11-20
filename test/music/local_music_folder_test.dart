import 'dart:async';

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/views/components/local_music_folder.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player() : super(PlayerState.init(null));

  List<LocalMusicTrack> queue = [];
  int? index;
  bool otherSession = false;
  final enqueued = <(String, bool)>[];

  @override
  bool get isOtherPlaybackSession => otherSession;

  @override
  bool get isLocalMusicSession => false;

  @override
  Future<void> enqueueLocalMusic(LocalMusicTrack track,
      {required bool playNext}) async {
    enqueued.add((track.title, playNext));
  }

  @override
  Future<void> playLocalMusic(List<LocalMusicTrack> tracks,
      {int startIndex = 0}) async {
    queue = tracks;
    index = startIndex;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends Cubit<SettingsState> implements SettingsCubit {
  _Settings()
      : super(SettingsState(
            settings: const {},
            packageInfo: PackageInfo(
                appName: '', packageName: '', version: '', buildNumber: '')));

  @override
  Future<void> saveSetting(SettingsValue setting) async {
    emit(state.copyWith(settings: {...state.settings, setting.name: setting}));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
  const tree = 'content://provider/tree/music';
  const picked = {'uri': tree, 'name': 'My albums'};
  const system = 'content://media/external/audio/media';
  const systemSelection = {
    'uri': system,
    'name': 'Android music library',
    'selectionId': 'system-test',
  };
  const first = {
    'title': 'First',
    'artist': 'Artist',
    'album': 'Album',
    'uri': '$tree/document/First',
    'fileName': 'original.mp3',
    'canRename': true,
    'addedMs': 5000,
    'modifiedMs': 1000,
  };
  const second = {
    'title': 'Second',
    'artist': 'Artist',
    'album': 'Album',
    'uri': '$tree/document/Second',
    'addedMs': 1000,
    'modifiedMs': 5000,
  };
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late LocalMusicLibrary library;
  late _Player player;
  late _Settings preferences;
  late List<String> calls;
  Map<String, String>? consent;
  bool cancelled = false;
  bool revoked = false;
  bool pickerUnavailable = false;
  bool denied = false;
  Completer<List<Object?>>? pendingScan;
  Completer<bool>? pendingAccess;
  int? scanId;
  String? renamedTo;

  setUp(() {
    library = LocalMusicLibrary();
    player = _Player();
    preferences = _Settings();
    calls = [];
    consent = null;
    cancelled = false;
    revoked = false;
    pickerUnavailable = false;
    denied = false;
    pendingScan = null;
    pendingAccess = null;
    scanId = null;
    renamedTo = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'getFolder':
          return consent;
        case 'pickFolder':
          if (pickerUnavailable) {
            throw PlatformException(code: 'PICKER_UNAVAILABLE');
          }
          if (cancelled) return null;
          revoked = false;
          return consent = picked;
        case 'pickSystem':
          if (denied) throw PlatformException(code: 'AUDIO_PERMISSION_DENIED');
          return consent = systemSelection;
        case 'listTracks':
          expect(call.arguments['treeUri'], consent?['uri']);
          if (revoked) throw PlatformException(code: 'FOLDER_UNAVAILABLE');
          scanId = call.arguments['scanId'] as int?;
          if (pendingScan != null) return pendingScan!.future;
          if (consent == systemSelection) {
            return [
              {'title': 'Indexed track', 'uri': '$system/1'}
            ];
          }
          return [first, second];
        case 'checkFolderAccess':
          expect(call.arguments['treeUri'], consent?['uri']);
          if (pendingAccess != null) return pendingAccess!.future;
          return !revoked;
        case 'renameTrack':
          expect(call.arguments['uri'], first['uri']);
          renamedTo = call.arguments['name'] as String;
          return {
            ...first,
            'identityUri': first['uri'],
            'uri': '$tree/document/Renamed',
            'fileName': renamedTo,
          };
        case 'forgetFolder':
          consent = null;
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    library.dispose();
    await player.close();
    await preferences.close();
  });

  Future<void> show(WidgetTester tester,
      {required bool settings, bool settle = true}) async {
    await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<PlayerCubit>.value(value: player),
          BlocProvider<SettingsCubit>.value(value: preferences),
        ],
        child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
                body: settings
                    ? LocalMusicFolder.settings(
                        key: const ValueKey('settings'), library: library)
                    : LocalMusicFolder.library(
                        key: const ValueKey('library'), library: library)))));
    if (settle) await tester.pumpAndSettle();
  }

  testWidgets('settings asks before reading music and cancel keeps it off',
      (tester) async {
    await show(tester, settings: true);
    final switchTile = find.byType(SwitchListTile);
    expect(tester.widget<SwitchListTile>(switchTile).value, isFalse);
    expect(calls, ['getFolder']);
    cancelled = true;
    await tester.tap(switchTile);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(switchTile).value, isFalse);
    expect(calls, ['getFolder', 'pickFolder']);

    cancelled = false;
    await tester.tap(switchTile);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(switchTile).value, isTrue);
    expect(find.text('My albums'), findsOneWidget);
    await tester.tap(switchTile);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(switchTile).value, isFalse);
    expect(calls.last, 'forgetFolder');
  });

  testWidgets('remote Select opens the picker and handles its absence',
      (tester) async {
    pickerUnavailable = true;
    await show(tester, settings: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(calls, ['getFolder', 'pickFolder']);
    expect(find.textContaining('folder picker is unavailable'), findsOneWidget);
    expect(library.enabled, isFalse);
  });

  testWidgets('resuming removes revoked tracks and shows the reconnect action',
      (tester) async {
    consent = picked;
    await show(tester, settings: false);
    expect(find.text('First'), findsOneWidget);
    calls.clear();
    revoked = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls, ['checkFolderAccess']);
    expect(find.text('First'), findsNothing);
    expect(
        find.textContaining('Access to this folder was lost'), findsOneWidget);
    expect(find.text('Choose music folder'), findsOneWidget);
  });

  testWidgets('returning to On this device rechecks an already loaded library',
      (tester) async {
    consent = picked;
    await show(tester, settings: false);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    calls.clear();
    revoked = true;
    await show(tester, settings: false);
    expect(calls, ['checkFolderAccess']);
    expect(find.text('First'), findsNothing);
    expect(
        find.textContaining('Access to this folder was lost'), findsOneWidget);
  });

  testWidgets('uncovering a mounted library route also rechecks access',
      (tester) async {
    consent = picked;
    await show(tester, settings: false);
    final nav = Navigator.of(tester.element(find.text('First')));
    nav.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Another screen'))));
    await tester.pumpAndSettle();
    calls.clear();
    revoked = true;
    nav.pop();
    await tester.pumpAndSettle();
    expect(calls, ['checkFolderAccess']);
    expect(find.text('First'), findsNothing);
    expect(
        find.textContaining('Access to this folder was lost'), findsOneWidget);
  });

  testWidgets('return from player keeps verified songs visible during recheck',
      (tester) async {
    consent = picked;
    await show(tester, settings: false);
    final navigator = Navigator.of(tester.element(find.text('First')));
    navigator.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Player screen'))));
    await tester.pumpAndSettle();
    pendingAccess = Completer<bool>();
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);

    pendingAccess!.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('First'), findsNothing);
    expect(
        find.textContaining('Access to this folder was lost'), findsOneWidget);
  });

  testWidgets(
      'Library browses and queues the selected folder and handles lost access',
      (tester) async {
    await show(tester, settings: false);
    final choose = find.text('Choose music folder');
    expect(choose, findsOneWidget);
    expect(calls, ['getFolder']);
    await tester.tap(choose);
    await tester.pumpAndSettle();
    expect(find.text('My albums'), findsOneWidget);
    expect(find.text('Artist • Album'), findsNWidgets(2));
    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    expect(player.queue.map((t) => t.title), ['First', 'Second']);
    expect(player.index, 1);

    revoked = true;
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Access to this folder was lost'), findsOneWidget);
    expect(find.text('First'), findsNothing);
    await tester.tap(choose);
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);
    await tester.tap(find.text('Forget folder'));
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsNothing);
    expect(choose, findsOneWidget);
    expect(calls.last, 'forgetFolder');
  });

  testWidgets('permission denial preserves the folder and lets users retry',
      (tester) async {
    consent = picked;
    await show(tester, settings: false);
    denied = true;
    await tester.tap(find.text('Use Android music library'));
    await tester.pumpAndSettle();
    expect(find.text('My albums'), findsOneWidget);
    expect(find.text('First'), findsOneWidget);
    expect(find.textContaining('Music and audio access is unavailable'),
        findsOneWidget);

    denied = false;
    await tester.tap(find.text('Use Android music library'));
    await tester.pumpAndSettle();
    expect(find.text('Android music library'), findsOneWidget);
    expect(find.text('Indexed track'), findsOneWidget);
    expect(find.text('First'), findsNothing);
  });

  testWidgets('early rows play the visible snapshot while indexing continues',
      (tester) async {
    consent = picked;
    pendingScan = Completer<List<Object?>>();
    await show(tester, settings: false, settle: false);
    await tester.pump();
    const codec = StandardMethodCodec();
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall('trackBatch', {
        'scanId': scanId,
        'tracks': [first],
      })),
      (_) {},
    );
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.tap(find.text('First'));
    await tester.pump();
    expect(player.queue.map((track) => track.title), ['First']);
    pendingScan!.complete([first, second]);
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsOneWidget);
    expect(player.queue.map((track) => track.title), ['First']);
  });

  testWidgets('sort changes new playback order without rescanning',
      (tester) async {
    consent = picked;
    await show(tester, settings: false);
    await tester.tap(find.byTooltip('Sort by'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Date modified'));
    await tester.tap(find.text('Descending'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(preferences.state.settings['local-music-sort']?.value,
        'dateModified:descending');
    expect(calls.where((method) => method == 'listTracks'), hasLength(1));
    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    expect(player.queue.map((t) => t.title), ['Second', 'First']);
    expect(player.index, 0);
  });

  testWidgets('rename uses the actual filename and retains its suffix',
      (tester) async {
    consent = picked;
    await show(tester, settings: false);
    await tester.tap(find.byTooltip('Actions for First'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename file'));
    await tester.pumpAndSettle();
    expect(find.text('original'), findsOneWidget);
    expect(find.text('.mp3'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'New name');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(renamedTo, 'New name.mp3');
    expect(library.tracks.first.fileName, 'New name.mp3');
    expect(find.text('First'), findsOneWidget);
  });

  testWidgets('queue actions add local songs or confirm source replacement',
      (tester) async {
    consent = picked;
    await show(tester, settings: false);
    await tester.tap(find.byTooltip('Actions for First'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play next'));
    await tester.pumpAndSettle();
    expect(player.enqueued, [('First', true)]);

    player.otherSession = true;
    await tester.tap(find.byTooltip('Actions for Second'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to queue'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(player.queue, isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, 'Start local queue'));
    await tester.pumpAndSettle();
    expect(player.queue.map((track) => track.title), ['Second']);
    expect(player.enqueued, [('First', true)]);
  });

  testWidgets('remote Select activates a focused local song menu action',
      (tester) async {
    consent = picked;
    await show(tester, settings: false);
    await tester.tap(find.byTooltip('Actions for First'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(player.enqueued, [('First', true)]);
    expect(find.text('Play next'), findsNothing);
  });
}
