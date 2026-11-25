import 'dart:async';
import 'dart:io';

import 'package:back_button_interceptor/back_button_interceptor.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart' as globals;
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/on_device_music_entry.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/on_device_music_downloads.dart';
import 'package:clipious/music/views/components/device_music_artwork.dart';
import 'package:clipious/music/views/components/local_music_folder.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _App extends Cubit<AppState> implements AppCubit {
  _App()
      : super(AppState(0, null, HomeLayout(), profileId: globals.db.profileId));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player() : super(PlayerState.init(null));

  List<LocalMusicTrack> queue = [];
  List<OnDeviceMusicEntry> mixedQueue = [];
  int? index;
  String? source;
  bool otherSession = false;
  final enqueued = <(String, bool)>[];

  @override
  final musicSelectionFailureRevision = ValueNotifier(0);

  @override
  bool get isOtherPlaybackSession => otherSession;

  @override
  bool get isLocalMusicSession => false;

  @override
  bool canAddDeviceMusicRequest(OnDeviceMusicEntry entry) => false;

  @override
  Future<void> enqueueLocalMusic(LocalMusicTrack track,
      {required bool playNext}) async {
    enqueued.add((track.title, playNext));
  }

  @override
  Future<void> playLocalMusic(List<LocalMusicTrack> tracks,
      {int startIndex = 0, String? queueTitle, bool songTap = false}) async {
    queue = tracks;
    index = startIndex;
    source = queueTitle;
  }

  @override
  Future<void> playOnDeviceMusic(List<OnDeviceMusicEntry> tracks,
      {int startIndex = 0,
      String? queueTitle,
      bool Function()? isCurrent,
      bool songTap = false}) async {
    expect(isCurrent?.call(), isNot(false));
    mixedQueue = tracks;
    index = startIndex;
    source = queueTitle;
  }

  @override
  Future<void> close() async {
    musicSelectionFailureRevision.dispose();
    await super.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Downloads extends Cubit<DownloadManagerState>
    implements DownloadManagerCubit {
  _Downloads(super.initialState);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends Cubit<SettingsState> implements SettingsCubit {
  _Settings(this.database) : super(SettingsState.init());

  final SembastSqfDb database;

  @override
  Future<void> reloadForProfile() async => emit(SettingsState.init());

  @override
  Future<void> setMusicCollectionPreference(String name, String value) async {
    final owner = database.forProfile(database.profileId);
    await owner.saveSetting(SettingsValue(name, value));
    if (!isClosed && owner.profileId == database.profileId) {
      await reloadForProfile();
    }
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
  late SembastSqfDb database;
  late _Player player;
  late _Settings preferences;
  late List<String> calls;
  late List<Object?> sharedFiles;
  bool canLaunchShare = true;
  Map<String, String>? consent;
  bool cancelled = false;
  bool revoked = false;
  bool pickerUnavailable = false;
  bool denied = false;
  bool automaticScan = false;
  Completer<List<Object?>>? pendingScan;
  Completer<bool>? pendingAccess;
  int? scanId;
  bool? forceScan;
  String? renamedTo;
  FutureOr<Map<String, Object?>?> Function(MethodCall)? matchDownloadTracks;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    globals.db = database;
    library = LocalMusicLibrary(visibilityDatabase: () => database);
    player = _Player();
    preferences = _Settings(database);
    calls = [];
    sharedFiles = [];
    canLaunchShare = true;
    consent = null;
    cancelled = false;
    revoked = false;
    pickerUnavailable = false;
    denied = false;
    automaticScan = false;
    pendingScan = null;
    pendingAccess = null;
    scanId = null;
    forceScan = null;
    renamedTo = null;
    matchDownloadTracks = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'getFolder':
          return call.arguments?['includeScanPreference'] == true
              ? {'folder': consent, 'automaticScan': automaticScan}
              : consent;
        case 'setAutomaticScan':
          automaticScan = call.arguments['enabled'] as bool;
          return null;
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
          forceScan = call.arguments['force'] as bool?;
          if (pendingScan != null) return pendingScan!.future;
          if (consent == systemSelection) {
            return [
              {'title': 'Indexed track', 'uri': '$system/1'}
            ];
          }
          return [first, second];
        case 'cancelScan':
          expect(call.arguments['scanId'], scanId);
          return null;
        case 'matchDownloadTracks':
          return await matchDownloadTracks?.call(call);
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
        case 'shareTrack':
          sharedFiles.add(call.arguments);
          return canLaunchShare;
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
    await database.close();
  });

  Future<void> show(WidgetTester tester,
      {required bool settings,
      bool settle = true,
      _App? app,
      _Downloads? manager,
      OnDeviceMusicDownloads? downloads}) async {
    await tester.pumpWidget(MultiBlocProvider(
        providers: [
          if (app != null) BlocProvider<AppCubit>.value(value: app),
          BlocProvider<PlayerCubit>.value(value: player),
          BlocProvider<SettingsCubit>.value(value: preferences),
          if (manager != null)
            BlocProvider<DownloadManagerCubit>.value(value: manager),
        ],
        child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
                body: settings
                    ? LocalMusicFolder.settings(
                        key: const ValueKey('settings'), library: library)
                    : LocalMusicFolder.library(
                        key: const ValueKey('library'),
                        library: library,
                        downloads: downloads)))));
    if (settle) await tester.pumpAndSettle();
  }

  testWidgets('settings asks before reading music and cancel keeps it off',
      (tester) async {
    await show(tester, settings: true);
    final switchTile = find.byKey(const ValueKey('local-music-setting'));
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

  testWidgets('settings shows and updates the saved refresh preference',
      (tester) async {
    automaticScan = true;
    await show(tester, settings: true);
    final toggle = find.widgetWithText(
        SwitchListTile, 'Automatically refresh device music');
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(automaticScan, isFalse);
    expect(calls, ['getFolder', 'setAutomaticScan']);
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
    await tester.enterText(find.byType(TextField), 'First');
    await tester.tap(find.widgetWithText(InputChip, 'Album'));
    await tester.pumpAndSettle();
    calls.clear();
    revoked = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls, ['checkFolderAccess']);
    expect(
        find.descendant(
            of: find.byType(BottomSheet),
            matching: find.text('No results found.')),
        findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('First'), findsNothing);
    expect(
        find.textContaining('Access to this folder was lost'), findsOneWidget);
    expect(find.text('Choose music folder'), findsOneWidget);
    revoked = false;
    await tester.tap(find.text('Use Android music library'));
    await tester.pumpAndSettle();
    expect(find.text('Indexed track'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
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
    expect(player.source, 'My albums');

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

  testWidgets('folder navigation keeps duplicate filenames and exact queues',
      (tester) async {
    consent = picked;
    Map<String, String> folder(String key, String label) =>
        {'key': key * 64, 'label': label};
    final root = folder('a', 'My albums');
    final discs = folder('b', 'My albums / Discs');
    final copies = folder('c', 'My albums / Copies');
    final discMix = folder('d', 'My albums / Discs / Mix');
    final copyMix = folder('e', 'My albums / Copies / Mix');
    const original = '$tree/document/take-a';
    const another = '$tree/document/take-b';
    const copy = '$tree/document/copy';
    Map<String, Object> duplicate(String uri, List<Map<String, String>> path) =>
        {
          'title': 'Same song',
          'fileName': 'same.mp3',
          'uri': uri,
          'folderLocations': path,
        };
    pendingScan = Completer<List<Object?>>()
      ..complete([
        {
          ...first,
          'folderLocations': [root]
        },
        {...second, 'title': 'Unlocated song'},
        duplicate(original, [root, discs, discMix]),
        duplicate(another, [root, discs, discMix]),
        duplicate(copy, [root, copies, copyMix]),
      ]);
    await show(tester, settings: false);
    final unlocated = find.text('Unlocated song');
    final trackList = find.descendant(
        of: find.byType(LocalMusicFolder),
        matching: find.byWidgetPredicate((widget) =>
            widget is Scrollable &&
            widget.axisDirection == AxisDirection.down));
    await tester.scrollUntilVisible(unlocated, 120, scrollable: trackList);
    expect(unlocated, findsOneWidget);
    await tester.scrollUntilVisible(find.text('Browse folders'), -120,
        scrollable: trackList);
    await tester.pumpAndSettle();

    Future<void> tap(Finder finder) async {
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    Finder row(String title) => find.widgetWithText(ListTile, title);
    await tap(find.text('Browse folders'));
    await tap(row('My albums'));
    expect(find.text('Unlocated song'), findsNothing);
    await tap(row('First'));
    expect(player.queue.map((track) => track.uri), [first['uri']]);
    expect(player.source, 'My albums');

    await tap(row('Discs'));
    await tap(row('Mix'));
    expect(find.text('same.mp3'), findsNWidgets(2));
    final secondId =
        library.tracks.singleWhere((track) => track.uri == another).playbackId;
    await tap(find.byKey(ValueKey(secondId)));
    expect(player.queue.map((track) => track.uri),
        unorderedEquals([original, another]));
    expect(player.queue[player.index!].uri, another);
    expect(player.source, 'My albums / Discs / Mix');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(row('Mix'), findsOneWidget);
    expect(row('Same song'), findsNothing);
    await tap(find.byTooltip('Back'));
    await tap(row('Copies'));
    await tap(row('Mix'));
    await tap(row('Same song'));
    expect(player.queue.single.uri, copy);
    expect(player.source, 'My albums / Copies / Mix');
  });

  testWidgets('MediaStore folders distinguish volumes and clear on access loss',
      (tester) async {
    consent = systemSelection;
    const internal = 'content://media/external_primary/audio/media/1';
    const removable = 'content://media/ABCD-1234/audio/media/1';
    Map<String, Object> entry(String uri, String key, String volume) => {
          'title': 'Same song',
          'fileName': 'same.mp3',
          'uri': uri,
          'visibilityKey': key * 64,
          'folderLocations': [
            {'key': key * 64, 'label': '$volume / Music'},
          ],
        };
    pendingScan = Completer<List<Object?>>()
      ..complete([
        entry(internal, 'a', 'Internal storage'),
        entry(removable, 'b', 'Storage SD'),
      ]);
    await show(tester, settings: false);
    await tester.tap(find.text('Browse folders'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Music'), findsNWidgets(2));
    await tester.tap(find.text('Storage SD'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Same song'));
    await tester.pumpAndSettle();
    expect(player.queue.single.uri, removable);

    await tester.tap(find.byTooltip('Actions for Same song'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide from this library'));
    await tester.pumpAndSettle();
    expect(find.text('Same song'), findsNothing);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Storage SD'), findsNothing);
    await tester.tap(find.text('Internal storage'));
    await tester.pumpAndSettle();
    expect(find.text('Same song'), findsOneWidget);

    revoked = true;
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Same song'), findsNothing);
    expect(find.text('Internal storage'), findsNothing);
    expect(find.textContaining('Music and audio access is unavailable'),
        findsOneWidget);
    expect(player.queue.single.uri, removable);
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

  testWidgets('browsing and managing roots handles one lost grant',
      (tester) async {
    const demosTree = 'content://provider/tree/demos';
    const demos = {'uri': demosTree, 'name': 'Demos'};
    const demoUri = '$demosTree/document/Demo';
    var added = false;
    var lostAccess = false;
    Map<String, Object> selection() => {
          'selectionId': 'device-library',
          'roots': [picked, if (added) demos],
        };

    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getFolder':
          return selection();
        case 'pickFolder':
          if (added) expect(call.arguments['initialUri'], demosTree);
          added = true;
          lostAccess = false;
          return selection();
        case 'checkFolderAccess':
          return call.arguments['treeUri'] != demosTree || !lostAccess;
        case 'listTracks':
          return call.arguments['treeUri'] == demosTree
              ? [
                  {
                    'title': 'Demo track',
                    'uri': demoUri,
                    'folderLocations': [
                      {'key': 'a' * 64, 'label': 'Demos'},
                    ],
                  },
                ]
              : [
                  {
                    ...first,
                    'folderLocations': [
                      {'key': 'b' * 64, 'label': 'My albums'},
                    ],
                  },
                ];
        case 'forgetFolder':
          expect(call.arguments['treeUri'], demosTree);
          added = false;
          return selection();
        default:
          throw MissingPluginException(call.method);
      }
    });

    await show(tester, settings: false);
    final manage = find.text('Manage music locations');
    await tester.tap(manage);
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    final add =
        find.descendant(of: sheet, matching: find.text('Add music folder'));
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.text('Demos'), findsOneWidget);
    expect(library.tracks.map((track) => track.title), ['First', 'Demo track']);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Browse folders'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'My albums'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'Demos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Demo track'));
    await tester.pumpAndSettle();
    expect(player.queue.single.uri, demoUri);

    lostAccess = true;
    await library.revalidate();
    await tester.pumpAndSettle();
    expect(library.tracks.map((track) => track.title), ['First']);
    expect(find.text('Demo track'), findsNothing);
    expect(find.text('No visible audio files.'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'My albums'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Demos'), findsNothing);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    await tester.tap(manage);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reconnect to restore access'));
    await tester.pumpAndSettle();
    expect(find.text('Reconnect to restore access'), findsNothing);
    expect(library.tracks.map((track) => track.title), ['First', 'Demo track']);

    await tester.tap(find.byTooltip('Remove Demos from music locations'));
    await tester.pumpAndSettle();
    expect(find.text('Demos'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('My albums'), findsOneWidget);
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Demo track'), findsNothing);
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

  testWidgets('device library can force a rescan and cancel it',
      (tester) async {
    consent = picked;
    await show(tester, settings: false);
    expect(forceScan, isFalse);

    pendingScan = Completer<List<Object?>>();
    calls.clear();
    final rescan = find.text('Rescan music files');
    await tester.tap(rescan);
    await tester.pump();
    expect(forceScan, isTrue);
    expect(rescan, findsNothing);
    expect(find.text('First'), findsOneWidget);

    final cancel = find.text('Cancel scan');
    await tester.tap(cancel);
    await tester.pump();
    expect(calls, ['listTracks', 'cancelScan']);
    pendingScan!.complete([
      {...first, 'title': 'Late scan result'}
    ]);
    await tester.pumpAndSettle();
    expect(cancel, findsNothing);
    expect(rescan, findsOneWidget);
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
    expect(find.text('Late scan result'), findsNothing);
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
    expect(
        database
            .getSettings('music-collection-device-sort-v1:legacy-folder')
            ?.value,
        'dateModified:descending');
    expect(calls.where((method) => method == 'listTracks'), hasLength(1));
    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    expect(player.queue.map((t) => t.title), ['Second', 'First']);
    expect(player.index, 0);
  });

  testWidgets('device browse keeps sort tags, totals and playback in scope',
      (tester) async {
    consent = picked;
    pendingScan = Completer<List<Object?>>()
      ..complete([
        {...first, 'title': 'The Song 10', 'durationMs': 700, 'sizeBytes': 100},
        {...second, 'title': 'Song 2', 'durationMs': 500},
        {
          ...second,
          'uri': '$tree/document/Bonus',
          'title': 'Bonus',
          'titleSort': 'Song 20',
          'durationMs': 2100,
          'sizeBytes': 200,
        },
      ]);
    await show(tester, settings: false);
    expect(find.text('Total duration 00:03'), findsOneWidget);
    expect(find.text('Known size 300 B'), findsOneWidget);
    await tester.tap(find.text('Song 2'));
    await tester.pumpAndSettle();
    expect(player.queue.map((track) => track.title),
        ['Song 2', 'The Song 10', 'Bonus']);

    await tester.enterText(find.byType(TextField), 'song');
    await tester.pumpAndSettle();
    expect(find.text('Total duration 00:01'), findsOneWidget);
    expect(find.text('Known size 100 B'), findsOneWidget);
    expect(find.text('Bonus'), findsNothing);
  });

  testWidgets('device collection preferences survive reopening per profile',
      (tester) async {
    consent = {...picked, 'selectionId': 'remembered-folder'};
    pendingScan = Completer<List<Object?>>()
      ..complete([
        first,
        {...second, 'album': 'Studio'},
        {
          ...second,
          'title': 'Third',
          'artist': 'Guest',
          'uri': '$tree/document/Third',
        },
      ]);
    final firstProfile = database.profileId;
    final secondProfile = await tester.runAsync(() async {
      await database
          .saveSetting(SettingsValue('local-music-sort', 'title:descending'));
      return (await database.createProfile('Another person')).id;
    });
    await preferences.reloadForProfile();
    await show(tester, settings: false);
    await tester.tap(find.text('Third'));
    await tester.pumpAndSettle();
    final playing = player.queue;
    expect(playing.map((track) => track.title), ['Third', 'Second', 'First']);

    await tester.tap(find.byTooltip('Sort by'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Date added'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    for (final label in ['Artist', 'Album']) {
      await tester.tap(find.widgetWithText(InputChip, label));
      await tester.pumpAndSettle();
      await tester.tap(find
          .descendant(of: find.byType(BottomSheet), matching: find.text(label))
          .last);
      await tester.pumpAndSettle();
    }
    expect(find.widgetWithText(InputChip, 'Artist · Artist'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'Album · Album'), findsOneWidget);
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsNothing);
    expect(find.text('Third'), findsNothing);
    expect(player.queue, same(playing));

    await tester.enterText(find.byType(TextField), 'no matching title');
    await tester.pumpAndSettle();
    expect(find.text('First'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await preferences.close();
    preferences = _Settings(database);
    await show(tester, settings: false);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    expect(find.widgetWithText(InputChip, 'Artist · Artist'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'Album · Album'), findsOneWidget);
    expect(find.text('First'), findsOneWidget);
    expect(
        database
            .getSettings(
                'music-collection-device-sort-v1:selection:remembered-folder')
            ?.value,
        'dateAdded:descending');

    await tester.runAsync(() => database.useProfile(secondProfile!));
    await preferences.reloadForProfile();
    library.visibilityProfileChanged();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'Artist'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'Album'), findsOneWidget);
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);

    await tester.runAsync(() => database.useProfile(firstProfile));
    await preferences.reloadForProfile();
    library.visibilityProfileChanged();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'Artist · Artist'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'Album · Album'), findsOneWidget);
    expect(find.text('Second'), findsNothing);
    expect(player.queue, same(playing));
  });

  testWidgets('search matches local filenames and keeps the playing snapshot',
      (tester) async {
    consent = picked;
    await show(tester, settings: false);
    final search = find.byType(TextField);
    await tester.enterText(search, ' ÁRTIST   ORIGINAL.MP3 ');
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsNothing);
    await tester.tap(find.text('First'));
    await tester.pump();
    expect(player.queue.map((track) => track.title), ['First']);
    await tester.enterText(search, 'nonexistent');
    await tester.pumpAndSettle();
    expect(find.text('No results found.'), findsOneWidget);
    final clear =
        MaterialLocalizations.of(tester.element(search)).clearButtonTooltip;
    await tester.tap(find.byTooltip(clear));
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsOneWidget);
    expect(player.queue.map((track) => track.title), ['First']);
    expect(calls.where((call) => call == 'listTracks'), hasLength(1));
  });

  testWidgets(
      'hiding one same-title device file updates Find, filters and new playback',
      (tester) async {
    consent = {...picked, 'selectionId': 'folder-hide-test'};
    final hiddenFile = {
      ...first,
      'title': 'Reprise',
      'artist': 'First artist',
      'album': 'First edition',
      'visibilityKey': 'a' * 64,
    };
    final sameTitle = {
      ...second,
      'title': 'Reprise',
      'artist': 'Other artist',
      'album': 'Other edition',
      'visibilityKey': 'b' * 64,
    };
    final third = {
      ...second,
      'title': 'Third',
      'artist': 'Other artist',
      'album': 'Other edition',
      'uri': '$tree/document/Third',
      'visibilityKey': 'c' * 64,
    };
    pendingScan = Completer<List<Object?>>()
      ..complete([hiddenFile, sameTitle, third]);
    await show(tester, settings: false);

    final source = Uri.parse(tree);
    final original = LocalMusicTrack.fromDocument(hiddenFile, source)!;
    final copy = LocalMusicTrack.fromDocument(sameTitle, source)!;
    final other = LocalMusicTrack.fromDocument(third, source)!;
    final originalRow = find.byKey(ValueKey(original.playbackId));
    final copyRow = find.byKey(ValueKey(copy.playbackId));
    final search = find.byType(TextField);

    Future<void> hideOriginal() async {
      final action = find.descendant(
          of: originalRow, matching: find.byTooltip('Actions for Reprise'));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide from this library'));
      await tester.pumpAndSettle();
    }

    await tester.tap(originalRow);
    await tester.pumpAndSettle();
    expect(player.queue, hasLength(3));
    expect(player.queue[player.index!].playbackId, original.playbackId);
    final playingQueue = player.queue;

    await tester.enterText(search, 'original.mp3');
    await tester.pumpAndSettle();
    await hideOriginal();
    expect(originalRow, findsNothing);
    expect(find.text('No results found.'), findsOneWidget);
    expect(player.queue, same(playingQueue));
    expect(player.queue[player.index!].playbackId, original.playbackId);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(originalRow, findsOneWidget);
    expect(find.text('Hidden files'), findsNothing);

    await hideOriginal();
    await tester.enterText(search, '');
    await tester.pumpAndSettle();
    expect(originalRow, findsNothing);
    expect(copyRow, findsOneWidget);
    await tester.tap(find.widgetWithText(InputChip, 'Artist'));
    await tester.pumpAndSettle();
    expect(find.text('First artist'), findsNothing);
    await tester.tap(find.text('Other artist'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(InputChip, 'Album'));
    await tester.pumpAndSettle();
    expect(find.text('First edition'), findsNothing);
    await tester.tap(find.text('Other edition'));
    await tester.pumpAndSettle();
    await tester.tap(copyRow);
    await tester.pumpAndSettle();
    expect(player.queue.map((track) => track.playbackId),
        [copy.playbackId, other.playbackId]);
    expect(player.index, 0);

    await tester.ensureVisible(find.text('Hidden files'));
    await tester.tap(find.text('Hidden files'));
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    expect(find.descendant(of: sheet, matching: find.text('Reprise')),
        findsOneWidget);
    await tester
        .tap(find.descendant(of: sheet, matching: find.text('Restore')));
    await tester.pumpAndSettle();
    expect(find.text('No hidden files'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Hidden files'), findsNothing);
    expect(library.visibleTracks.map((track) => track.playbackId),
        contains(original.playbackId));
    expect(calls.where((call) => call == 'listTracks'), hasLength(1));
  });

  testWidgets(
      'local browsing brings in private downloads and hides only verified shared aliases',
      (tester) async {
    const storage = MethodChannel('videre/download_storage');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    const private = DownloadedVideo(
      videoId: 'private-song',
      title: 'Private song',
      quality: 'audio',
      audioOnly: true,
      downloadComplete: true,
      lengthSeconds: 60,
      musicMetadata: MusicMetadata(title: 'Private song', artist: 'Band'),
    );
    const aliasUri = 'content://media/external_primary/audio/media/1';
    const copyUri = 'content://media/external_primary/audio/media/2';
    final shared = private.copyWith(
      videoId: 'shared-song',
      title: 'Reprise',
      musicMetadata: const MusicMetadata(title: 'Reprise', artist: 'Band'),
      storageUri: aliasUri,
      folderUri: system,
    );
    final pending =
        private.copyWith(videoId: 'pending-song', downloadComplete: false);
    final foreign = private.copyWith(profileId: 'other', videoId: 'foreign');
    final downloads = OnDeviceMusicDownloads();
    final manager = _Downloads(
        DownloadManagerState(videos: [shared, private, pending, foreign]));
    final documents = await tester.runAsync(
      () => Directory.systemTemp.createTemp('videre-local-music-widget-'),
    );
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documents!.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(storage, null);
      messenger.setMockMethodCallHandler(pathProvider, null);
      downloads.dispose();
      await manager.close();
      await documents!.delete(recursive: true);
    });
    final privateProof = 'd' * 64;
    final sharedProof = 'e' * 64;
    final proofs = {private.videoId: privateProof, shared.videoId: sharedProof};
    messenger.setMockMethodCallHandler(storage, (call) async {
      if (call.method != 'probeMusicFiles') {
        throw MissingPluginException(call.method);
      }
      expect(call.arguments['profileId'], database.profileId);
      final files = call.arguments['files'] as List;
      expect(files.map((file) => file['videoId']),
          everyElement(isIn(proofs.keys)));
      return {
        for (final file in files)
          file['key']: {'identity': proofs[file['videoId']], 'byteLength': 3},
      };
    });
    matchDownloadTracks = (call) {
      expect(call.arguments['treeUri'], system);
      expect(call.arguments['selectionId'], systemSelection['selectionId']);
      final files = call.arguments['files'] as List;
      final sharedFile = files.singleWhere((file) => file['uri'] == aliasUri);
      expect(sharedFile['identity'], sharedProof);
      return {
        sharedFile['key'] as String: [aliasUri],
      };
    };

    await tester.runAsync(() async {
      final file = File(await private.downloadPath);
      await file.writeAsBytes([1, 2, 3]);
      await database.upsertDownload(private);
      await database.upsertDownload(shared);

      Finder downloadRow(DownloadedVideo file) => find.byKey(ValueKey(
          OnDeviceMusicEntry.download(file, proofs[file.videoId]!).id));
      Future<void> waitFor(Finder finder, Matcher occurrence) async {
        final timer = Stopwatch()..start();
        while (timer.elapsed < const Duration(seconds: 4)) {
          await tester.pump(const Duration(milliseconds: 40));
          if (occurrence.matches(finder, {})) return;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(finder, occurrence);
      }

      await show(tester,
          settings: false, manager: manager, downloads: downloads);
      final privateRow = downloadRow(private);
      await waitFor(privateRow, findsOneWidget);
      expect(find.text('Choose music folder'), findsOneWidget);
      expect(
          find.descendant(
              of: privateRow, matching: find.textContaining('Downloaded')),
          findsOneWidget);
      await tester.tap(privateRow);
      await tester.pumpAndSettle();
      expect(
          player.mixedQueue[player.index!].download?.videoId, private.videoId);
      expect(player.mixedQueue.every((entry) => entry.deviceTrack == null),
          isTrue);
      expect(calls, isNot(contains('pickFolder')));
      expect(calls, isNot(contains('pickSystem')));

      final alias = {
        'uri': aliasUri,
        'title': 'Reprise',
        'artist': 'Band',
        'visibilityKey': 'a' * 64,
        'fileName': 'shared.mp3',
      };
      final copy = {
        ...alias,
        'uri': copyUri,
        'visibilityKey': 'b' * 64,
        'fileName': 'other.mp3',
      };
      pendingScan = Completer<List<Object?>>()..complete([alias, copy]);
      await tester.tap(find.text('Use Android music library'));
      await tester.pumpAndSettle();
      final source = LocalMusicTrack.systemSource;
      final aliasId = LocalMusicTrack.fromDocument(alias, source)!.playbackId;
      final copyId = LocalMusicTrack.fromDocument(copy, source)!.playbackId;
      final aliasRow = find.byKey(ValueKey(aliasId));
      final copyRow = find.byKey(ValueKey(copyId));
      await waitFor(aliasRow, findsOneWidget);
      await waitFor(downloadRow(shared), findsNothing);
      expect(copyRow, findsOneWidget);
      expect(find.text('Reprise'), findsNWidgets(2));
      await tester.ensureVisible(privateRow);
      await tester.tap(privateRow);
      await tester.pumpAndSettle();
      expect(player.mixedQueue, hasLength(3));
      expect(
          player.mixedQueue[player.index!].download?.videoId, private.videoId);
      expect(player.mixedQueue[player.index!].downloadFileProof, privateProof);
      expect(player.mixedQueue.map((entry) => entry.deviceTrack?.playbackId),
          unorderedEquals([null, aliasId, copyId]));

      final action = find.descendant(
          of: aliasRow, matching: find.byTooltip('Actions for Reprise'));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide from this library'));
      await waitFor(aliasRow, findsNothing);
      await tester.pumpAndSettle();
      expect(downloadRow(shared), findsNothing);
      expect(copyRow, findsOneWidget);
      expect(manager.state.videos, contains(shared));
      expect(database.getDownloadByVideoId(shared.videoId), isNotNull);
      expect(library.containsUri(aliasUri), isTrue);

      await tester.tap(find.text('Undo'));
      await waitFor(aliasRow, findsOneWidget);
      expect(downloadRow(shared), findsNothing);
      expect(find.text('Reprise'), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
      'Library exclusions change Find and new queues and allow recovery',
      (tester) async {
    consent = systemSelection;
    final record = {
      'uri': '$system/1',
      'title': 'Labeled memo',
      'artist': 'Recording artist',
      'album': 'Recorder',
      'visibilityKey': 'a' * 64,
      'isRecording': true,
    };
    final demo = {
      'uri': '$system/2',
      'title': 'Scratch demo',
      'artist': 'Demo artist',
      'album': 'Drafts',
      'visibilityKey': 'b' * 64,
      'folderLocations': [
        {'key': 'c' * 64, 'label': 'Music / Drafts'},
      ],
    };
    const memo = {
      'uri': '$system/3',
      'title': 'Voice memo song',
      'artist': 'Band',
      'album': 'Set',
    };
    pendingScan = Completer<List<Object?>>()..complete([record, demo, memo]);
    await show(tester, settings: false);

    Future<void> tapSheet(String label) async {
      final button = find.descendant(
          of: find.byType(BottomSheet).last, matching: find.text(label));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    Future<void> closeSheet() async {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }

    Future<void> openRules() async {
      final button = find.text('Library exclusions');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    expect(find.text('Labeled memo'), findsOneWidget);
    await tester.tap(find.text('Scratch demo'));
    await tester.pumpAndSettle();
    final existing = player.queue;
    expect(existing.map((song) => song.title),
        ['Labeled memo', 'Scratch demo', 'Voice memo song']);
    final search = find.byType(TextField);
    await tester.enterText(search, 'memo');
    await tester.pumpAndSettle();

    await openRules();
    final toggle = find.widgetWithText(SwitchListTile, 'Hide voice recordings');
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tapSheet('Hide voice recordings');
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tapSheet('Exclude a folder');
    await tapSheet('Music / Drafts');
    await tapSheet('Excluded files');
    final recovery = find.byType(BottomSheet).last;
    final recordingRow = find.descendant(
        of: recovery, matching: find.widgetWithText(ListTile, 'Labeled memo'));
    final demoRow = find.descendant(
        of: recovery, matching: find.widgetWithText(ListTile, 'Scratch demo'));
    expect(recordingRow, findsOneWidget);
    expect(demoRow, findsOneWidget);
    expect(
        find.descendant(of: recovery, matching: find.text('Voice memo song')),
        findsNothing);
    await tester.tap(find.descendant(
        of: recordingRow, matching: find.text('Keep in library')));
    await tester.pumpAndSettle();
    expect(recordingRow, findsNothing);
    expect(demoRow, findsOneWidget);
    await closeSheet();
    await closeSheet();

    expect(player.queue, same(existing));
    expect(tester.widget<TextField>(search).controller!.text, 'memo');
    expect(find.text('Labeled memo'), findsOneWidget);
    expect(find.text('Voice memo song'), findsOneWidget);
    await tester.tap(find.widgetWithText(InputChip, 'Artist'));
    await tester.pumpAndSettle();
    expect(find.text('Demo artist'), findsNothing);
    await tapSheet('Recording artist');
    expect(find.text('Voice memo song'), findsNothing);
    await tester.tap(find.byTooltip('Actions for Labeled memo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove keep override'));
    await tester.pumpAndSettle();
    expect(find.text('Labeled memo'), findsNothing);
    expect(find.text('Voice memo song'), findsOneWidget);
    await tester.tap(find.text('Voice memo song'));
    await tester.pumpAndSettle();
    expect(player.queue.map((song) => song.title), ['Voice memo song']);

    await openRules();
    await tapSheet('Remove');
    await closeSheet();
    await tester.enterText(search, 'scratch');
    await tester.pumpAndSettle();
    expect(find.text('Scratch demo'), findsOneWidget);
    expect(find.text('Labeled memo'), findsNothing);

    await tester.enterText(search, '');
    await tester.pumpAndSettle();
    await openRules();
    await tapSheet('Include a folder');
    await tapSheet('Music / Drafts');
    expect(find.text('Included folders'), findsOneWidget);
    await tapSheet('Excluded files');
    final outsideFolder = find.descendant(
        of: find.byType(BottomSheet).last,
        matching: find.widgetWithText(ListTile, 'Voice memo song'));
    expect(
        find.descendant(
            of: outsideFolder, matching: find.text('Outside included folders')),
        findsOneWidget);
    await closeSheet();
    await closeSheet();
    expect(find.text('Scratch demo'), findsOneWidget);
    expect(find.text('Voice memo song'), findsNothing);

    await openRules();
    await tapSheet('Remove');
    await closeSheet();
    expect(find.text('Voice memo song'), findsOneWidget);
  });

  testWidgets('artist and album filters scope the playable list as tags arrive',
      (tester) async {
    consent = picked;
    pendingScan = Completer<List<Object?>>();
    await show(tester, settings: false, settle: false);
    await tester.pump();
    final rows = [
      {...first, 'artist': 'Singer', 'album': 'Live'},
      {...second, 'artist': 'Singer', 'album': 'Studio'},
    ];
    await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall('trackBatch', {
          'scanId': scanId,
          'tracks': rows,
        })),
        (_) {});
    await tester.pump();
    await tester.tap(find.widgetWithText(InputChip, 'Artist'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Singer'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    pendingScan!.complete([
      ...rows,
      {
        ...first,
        'title': 'Third',
        'artist': 'Guest',
        'album': 'Live',
        'uri': '$tree/document/Third'
      },
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Third'), findsNothing);
    await tester.tap(find.widgetWithText(InputChip, 'Album'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsNothing);
    await tester.tap(find.text('First'));
    await tester.pump();
    expect(player.queue.map((track) => track.title), ['First']);
    expect(calls.where((call) => call == 'listTracks'), hasLength(1));
  });

  testWidgets(
      'Albums and the album filter keep exact same-title editions apart',
      (tester) async {
    consent = picked;
    final compilation = 'a' * 64;
    final otherEdition = 'b' * 64;
    final app = _App();
    addTearDown(app.close);
    pendingScan = Completer<List<Object?>>()
      ..complete([
        {
          ...first,
          'albumKey': compilation,
          'albumArtist': 'Compilation credit',
          'trackNumber': 12,
          'adjacentArtPath': '/data/cache/compilation.jpg',
        },
        {
          ...second,
          'albumKey': compilation,
          'albumArtist': 'Compilation credit',
          'artist': 'Guest performer',
          'trackNumber': 2,
        },
        {
          ...first,
          'title': 'Distinct edition',
          'uri': '$tree/document/edition',
          'albumKey': otherEdition,
          'albumArtist': 'Solo credit',
        },
      ]);
    await show(tester, settings: false, app: app);
    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey(compilation)), findsOneWidget);
    expect(find.byKey(ValueKey(otherEdition)), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(ValueKey(compilation)),
            matching: find.byType(DeviceMusicArtwork)),
        findsOneWidget);
    await tester.tap(find.byKey(ValueKey(compilation)));
    await tester.pumpAndSettle();
    expect(find.text('Compilation credit'), findsOneWidget);
    expect(find.text('Guest performer'), findsOneWidget);
    expect(find.text('Distinct edition'), findsNothing);
    expect(find.byType(DeviceMusicArtwork), findsOneWidget);
    await tester.tap(find.text('Play all'));
    await tester.pumpAndSettle();
    expect(player.queue.map((track) => track.title), ['Second', 'First']);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(InputChip, 'Album'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Solo credit'));
    await tester.pumpAndSettle();
    expect(find.text('Distinct edition'), findsOneWidget);
    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await show(tester, settings: false, app: app);
    expect(find.widgetWithText(InputChip, 'Album · Album'), findsOneWidget);
    expect(find.text('Distinct edition'), findsOneWidget);
    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsNothing);
  });

  testWidgets('catalog refresh drops vanished tags and retains the search',
      (tester) async {
    consent = picked;
    await show(tester, settings: false);
    await tester.tap(find.widgetWithText(InputChip, 'Artist'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Artist').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(InputChip, 'Album'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Album').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'first');
    await tester.pumpAndSettle();
    expect(find.text('Artist · Artist'), findsOneWidget);
    expect(find.text('Album · Album'), findsOneWidget);

    pendingScan = Completer<List<Object?>>();
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump();
    expect(find.text('Artist · Artist'), findsOneWidget);
    pendingScan!.complete([
      {...first, 'artist': 'Updated artist'},
      {...second, 'artist': 'Updated artist'},
    ]);
    await tester.pumpAndSettle();
    expect(library.error, isNull);
    expect(library.tracks.map((track) => track.artist),
        ['Updated artist', 'Updated artist']);
    expect(find.text('Artist · Artist'), findsNothing);
    expect(find.text('Album · Album'), findsNothing);
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsNothing);
  });

  testWidgets('catalog refresh to empty leaves an active query clearable',
      (tester) async {
    consent = picked;
    await show(tester, settings: false);
    final search = find.byType(TextField);
    await tester.enterText(search, 'original');
    await tester.pumpAndSettle();
    pendingScan = Completer<List<Object?>>()..complete([]);
    await library.refresh();
    await tester.pumpAndSettle();
    expect(search, findsOneWidget);
    final clear =
        MaterialLocalizations.of(tester.element(search)).clearButtonTooltip;
    await tester.tap(find.byTooltip(clear));
    await tester.pumpAndSettle();
    pendingScan = null;
    await library.refresh();
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsOneWidget);
  });

  testWidgets('device row shares one audio URI and keeps its source selected',
      (tester) async {
    consent = {...picked, 'selectionId': 'music-share-selection'};
    await show(tester, settings: false);
    calls.clear();

    Future<void> shareFirst() async {
      await tester.tap(find.byTooltip('Actions for First'));
      await tester.pumpAndSettle();
      expect(find.text('Share song link'), findsNothing);
      await tester.tap(find.text('Share audio file'));
      await tester.pumpAndSettle();
    }

    await shareFirst();
    expect(sharedFiles, [
      {
        'treeUri': tree,
        'selectionId': 'music-share-selection',
        'uri': first['uri'],
        'trackId': library.tracks.first.playbackId,
      },
    ]);
    // Bringing the chooser forward also revalidates the authorized root.
    expect(calls, ['shareTrack', 'checkFolderAccess']);
    expect(library.enabled, isTrue);
    expect(library.tracks.length, 2);

    canLaunchShare = false;
    await shareFirst();
    expect(find.text('Could not share this audio file.'), findsOneWidget);
    expect(calls, [
      'shareTrack',
      'checkFolderAccess',
      'shareTrack',
      'checkFolderAccess',
    ]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

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

  testWidgets(
      'player rename handles Back before the queue and rejects a stale selection',
      (tester) async {
    consent = picked;
    await show(tester, settings: false);
    var current = true;
    Future<void> openRename() => renameLocalMusicTrack(
        tester.element(find.byType(LocalMusicFolder)),
        library,
        library.tracks.first,
        inPlayer: true,
        isCurrent: () => current);

    var queueBack = false;
    bool closeQueue(bool stopped, RouteInfo info) {
      queueBack = true;
      return true;
    }

    BackButtonInterceptor.add(closeQueue, zIndex: 4, ifNotYetIntercepted: true);
    addTearDown(() => BackButtonInterceptor.remove(closeQueue));
    final cancelled = openRename();
    await tester.pumpAndSettle();
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.navigation.name,
        SystemChannels.navigation.codec
            .encodeMethodCall(const MethodCall('popRoute')),
        null);
    await tester.pumpAndSettle();
    await cancelled;
    expect(find.byType(AlertDialog), findsNothing);
    expect(queueBack, isFalse);

    final stale = openRename();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'New name');
    current = false;
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await stale;
    expect(calls, isNot(contains('renameTrack')));
    expect(library.tracks.first.fileName, 'original.mp3');
  });

  testWidgets('rename leaves a file changed by another action alone',
      (tester) async {
    consent = picked;
    await show(tester, settings: false);
    final track = library.tracks.first;
    final dialog = renameLocalMusicTrack(
        tester.element(find.byType(LocalMusicFolder)), library, track);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Earlier edit');
    expect(await library.renameTrack(track, 'Later edit.mp3'), isTrue);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await dialog;
    expect(calls.where((method) => method == 'renameTrack'), hasLength(1));
    expect(library.tracks.first.fileName, 'Later edit.mp3');
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
