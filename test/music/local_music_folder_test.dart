import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/views/components/local_music_folder.dart';
import 'package:clipious/player/states/player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player() : super(PlayerState.init(null));

  List<LocalMusicTrack> queue = [];
  int? index;

  @override
  Future<void> playLocalMusic(List<LocalMusicTrack> tracks,
      {int startIndex = 0}) async {
    queue = tracks;
    index = startIndex;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
  const tree = 'content://provider/tree/music';
  const picked = {'uri': tree, 'name': 'My albums'};
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late LocalMusicLibrary library;
  late _Player player;
  late List<String> calls;
  Map<String, String>? consent;
  bool cancelled = false;
  bool revoked = false;
  bool pickerUnavailable = false;

  setUp(() {
    library = LocalMusicLibrary();
    player = _Player();
    calls = [];
    consent = null;
    cancelled = false;
    revoked = false;
    pickerUnavailable = false;
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
        case 'listTracks':
          expect(call.arguments['treeUri'], tree);
          if (revoked) throw PlatformException(code: 'FOLDER_UNAVAILABLE');
          return [
            for (final title in ['First', 'Second'])
              {
                'title': title,
                'artist': 'Artist',
                'album': 'Album',
                'uri': '$tree/document/$title',
                'durationMs': 12000,
              }
          ];
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
  });

  Future<void> show(WidgetTester tester, {required bool settings}) async {
    await tester.pumpWidget(BlocProvider<PlayerCubit>.value(
        value: player,
        child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
                body: settings
                    ? LocalMusicFolder.settings(
                        key: const ValueKey('settings'), library: library)
                    : LocalMusicFolder.library(
                        key: const ValueKey('library'), library: library)))));
    await tester.pumpAndSettle();
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
}
