import 'dart:async';
import 'dart:ui' as ui;

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_playlist_covers.dart';
import 'package:clipious/music/views/components/music_playlist_cover.dart';
import 'package:clipious/service.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart' show newDatabaseFactoryMemory;

class _App extends AppCubit {
  _App() : super(AppState(0, null, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  void initState() {}

  @override
  void onReady() {}
}

Future<Uint8List> _image(int width, int height, int color) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(ui.Color(color), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const playlist = 'local:playlist-test';

  test('playlist covers persist, resize and reset per profile', () async {
    final factory = newDatabaseFactoryMemory();
    var database = SembastSqfDb(await factory.openDatabase('playlist-covers'));
    await database.getProfiles();
    final first = database.profileId;
    final second = (await database.createProfile('Second')).id;
    var covers = MusicPlaylistCovers.forProfile(database, first);
    final foreign = MusicPlaylistCovers.forProfile(database, second);
    final red = await _image(600, 400, 0xffff0000);
    final blue = await _image(400, 600, 0xff0000ff);

    expect(await covers.save(playlist, red, isCurrent: () => true), isTrue);
    final original = covers.encodedCover(playlist);
    expect(original, isNotNull);
    expect(foreign.encodedCover(playlist), isNull);
    final normalized =
        await ui.instantiateImageCodec(MusicPlaylistCovers.decode(original)!);
    final frame = (await normalized.getNextFrame()).image;
    expect((frame.width, frame.height), (320, 213));
    frame.dispose();
    normalized.dispose();

    await foreign.save(playlist, blue, isCurrent: () => true);
    final other = foreign.encodedCover(playlist);
    expect(other, isNot(equals(original)));
    final backup = await database.exportBackup();
    expect(backup.encode(), isNot(contains(original!)));
    await database.close();

    database = SembastSqfDb(await factory.openDatabase('playlist-covers'));
    addTearDown(database.close);
    await database.getProfiles();
    covers = MusicPlaylistCovers.forProfile(database, first);
    expect(covers.encodedCover(playlist), original);
    expect(await covers.reset(playlist), isTrue);
    expect(covers.encodedCover(playlist), isNull);
    expect(
        MusicPlaylistCovers.forProfile(database, second).encodedCover(playlist),
        other);
    await database.deleteProfile(second);
    expect(() => MusicPlaylistCovers.forProfile(database, second),
        throwsStateError);
  });

  test('invalid images and expired sessions preserve the current cover',
      () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    final covers = MusicPlaylistCovers.forProfile(database, database.profileId);
    final red = await _image(24, 24, 0xffff0000);
    final blue = await _image(24, 24, 0xff0000ff);
    await covers.save(playlist, red, isCurrent: () => true);
    final saved = covers.encodedCover(playlist);

    await expectLater(
        covers.save(playlist, Uint8List.fromList([1, 2, 3]),
            isCurrent: () => true),
        throwsA(anything));
    var checks = 0;
    expect(await covers.save(playlist, blue, isCurrent: () => ++checks == 1),
        isFalse);
    expect(await covers.reset(playlist, isCurrent: () => false), isFalse);
    expect(covers.encodedCover(playlist), saved);

    expect(await covers.save(playlist, blue, isCurrent: () => true), isTrue);
    expect(covers.encodedCover(playlist), isNot(equals(saved)));
    await expectLater(covers.save('PL-public', red, isCurrent: () => true),
        throwsArgumentError);
  });

  testWidgets('cover editor picks, cancels and resets', (tester) async {
    const channel = MethodChannel('videre/files');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previousService = service;
    service = Service();
    final database = await tester.runAsync(SembastSqfDb.createInMemory);
    db = database!;
    final app = _App();
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await app.close();
      await database.close();
      service = previousService;
    });
    final id = (await tester
        .runAsync(() => service.createPlayList('Cover test', 'local')))!;
    final cover = await tester.runAsync(() => _image(24, 24, 0xff0000ff));
    final library = MusicLibraryService.forProfile(database, db.profileId);
    final covers = MusicPlaylistCovers.forProfile(database, db.profileId);
    Uint8List? reply = cover;
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'openPlaylistCover');
      expect(call.arguments, isNull);
      calls++;
      return reply;
    });

    await tester.pumpWidget(BlocProvider<AppCubit>.value(
        value: app,
        child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
                body: ListenableBuilder(
                    listenable: library.changes,
                    builder: (_, __) => MusicPlaylistCoverEditor(
                        covers: covers, playlistId: id))))));
    await tester.pumpAndSettle();
    final choose = find.text('Choose cover');
    final reset = find.text('Reset cover');
    expect(choose, findsOneWidget);
    expect(reset, findsNothing);

    Future<void> edit(Finder action, bool Function() done) async {
      await tester.runAsync(() async {
        await tester.tap(action);
        await Future.doWhile(() async {
          if (done()) return false;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          return true;
        }).timeout(const Duration(seconds: 5));
      });
      await tester.pumpAndSettle();
    }

    await edit(choose, () => covers.encodedCover(id) != null);
    final selected = covers.encodedCover(id);
    expect(find.byType(Image), findsOneWidget);
    expect(reset, findsOneWidget);

    reply = null;
    await edit(choose, () => calls == 2);
    expect(covers.encodedCover(id), selected);
    expect(reset, findsOneWidget);

    await edit(reset, () => covers.encodedCover(id) == null);
    expect(find.byType(Image), findsNothing);
    expect(reset, findsNothing);
    expect(choose, findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
