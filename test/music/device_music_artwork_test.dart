import 'dart:convert';
import 'dart:io';

import 'package:clipious/globals.dart';
import 'package:clipious/music/models/device_music_artwork_preferences.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/views/components/device_music_artwork.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const png =
      'iVBORw0KGgoAAAANSUhEUgAAACAAAAASCAIAAAC1qksFAAAAKklEQVR4nGP4z8BAEiJNNRlo1IJRC4ajBaTq+P+fgSQ0asGoBaMW/GcAAMouzU/PxmgLAAAAAElFTkSuQmCC';
  const placeholder = Text('No cover');
  late Directory files;
  late File adjacent;
  late File embedded;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    files = Directory.systemTemp.createTempSync('device-music-cover-');
    adjacent = File.fromUri(files.uri.resolve('adjacent.png'));
    embedded = File.fromUri(files.uri.resolve('embedded.png'))
      ..writeAsBytesSync(base64Decode(png));
  });

  tearDown(() async {
    await db.close();
    files.deleteSync(recursive: true);
  });

  Future<void> show(WidgetTester tester,
          {double size = 240, Widget? artwork}) =>
      tester.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: size,
            child: artwork ??
                DeviceMusicArtwork(
                  track: LocalMusicTrack(
                    uri: 'content://documents/song',
                    title: 'Device track',
                    artPath: embedded.path,
                    adjacentArtPath: adjacent.path,
                  ),
                  placeholder: placeholder,
                ),
          ),
        ),
      ));

  Image image(WidgetTester tester) => tester.widget<Image>(find.byType(Image));

  Future<void> waitForDecodedImage(WidgetTester tester) async {
    final loaded = find.byWidgetPredicate(
        (widget) => widget is RawImage && widget.image != null);
    // File I/O and image decoding complete outside the widget test clock.
    for (var i = 0; i < 40 && loaded.evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(loaded, findsOneWidget);
  }

  testWidgets('adjacent source, decode budget and crop react to preferences',
      (tester) async {
    adjacent.writeAsBytesSync(base64Decode(png));
    await show(tester);
    expect(image(tester).fit, BoxFit.cover);
    var provider = image(tester).image as ResizeImage;
    expect(provider.imageProvider, FileImage(adjacent));
    expect((provider.width, provider.height), (512, 512));
    expect(provider.policy, ResizeImagePolicy.fit);
    await waitForDecodedImage(tester);

    await tester.runAsync(() async {
      await DeviceMusicArtworkPreferences.setQuality(
          db, DeviceMusicArtworkQuality.high);
      await DeviceMusicArtworkPreferences.setCrop(
          db, DeviceMusicArtworkCrop.fit);
    });
    await tester.pump();
    provider = image(tester).image as ResizeImage;
    expect((provider.width, provider.height), (1024, 1024));
    expect(image(tester).fit, BoxFit.contain);
    await waitForDecodedImage(tester);

    await show(tester, size: 48);
    provider = image(tester).image as ResizeImage;
    expect((provider.width, provider.height), (144, 144));
    await waitForDecodedImage(tester);

    await tester.runAsync(() => DeviceMusicArtworkPreferences.setSource(
        db, DeviceMusicArtworkSource.embeddedOnly));
    await tester.pump();
    expect(image(tester).image, FileImage(embedded));
    expect(image(tester).fit, BoxFit.contain);
    await waitForDecodedImage(tester);
  });

  for (final corrupt in [false, true]) {
    testWidgets(
        '${corrupt ? 'corrupt album' : 'missing'} adjacent art uses embedded',
        (tester) async {
      if (corrupt) adjacent.writeAsStringSync('not an image');
      await show(tester,
          artwork: corrupt
              ? DeviceMusicArtwork.album(
                  tracks: [
                    LocalMusicTrack(
                      uri: 'content://documents/first',
                      title: 'First track',
                      adjacentArtPath: adjacent.path,
                    ),
                    LocalMusicTrack(
                      uri: 'content://documents/second',
                      title: 'Second track',
                      artPath: embedded.path,
                    ),
                  ],
                  placeholder: placeholder,
                )
              : null);
      await waitForDecodedImage(tester);
      expect(find.image(FileImage(embedded)), findsOneWidget);
      expect(find.byWidget(placeholder), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
