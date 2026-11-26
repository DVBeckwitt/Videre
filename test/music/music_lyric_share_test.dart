import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/device_music_artwork_preferences.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/services/music_lyric_share.dart';
import 'package:clipious/music/services/music_lyric_share_artwork.dart';
import 'package:clipious/music/views/components/music_lyric_share_button.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const origin = ui.Rect.fromLTWH(20, 40, 80, 40);
  const lyrics = ['تشرق الشمس', 'Café e chuva 🎶'];
  const attribution = 'أغنية — مؤدٍ\nSource: LRCLIB';
  const fixtureArtworkColor = 0xe65309ff;

  MusicLyricShare excerpt(List<String> lines) => MusicLyricShare(
        lines: lines,
        attribution: attribution,
        textDirection: ui.TextDirection.rtl,
      );

  test('text preserves the selected lines and attribution', () {
    final payload = excerpt(lyrics).text(sharePositionOrigin: origin);

    expect(payload.text, '${lyrics.join('\n')}\n\n$attribution');
    expect(payload.sharePositionOrigin, origin);
  });

  test('image is a bounded PNG with a native share anchor', () async {
    final payload = await excerpt(lyrics).image(sharePositionOrigin: origin);

    expect(payload.sharePositionOrigin, origin);
    expect(payload.fileNameOverrides, ['videre-lyrics.png']);
    final file = payload.files!.single;
    expect(file.mimeType, 'image/png');
    final bytes = await file.readAsBytes();
    expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);

    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      try {
        expect(frame.image.width, 1080);
        expect(frame.image.height, inInclusiveRange(1, 2048));
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  });

  test('every layout fits short and long selections with and without artwork',
      () async {
    const palette = MusicLyricSharePalette.parchment;
    const lyricInk = 0x361b12ff;
    const attributionInk = 0x69432dff;
    final artwork = await _makeArtwork();
    addTearDown(artwork.dispose);

    for (final layout in MusicLyricShareLayout.values) {
      for (final long in [false, true]) {
        final direction = long ? ui.TextDirection.rtl : ui.TextDirection.ltr;
        for (final withArtwork in [false, true]) {
          final description = '${layout.name}, long: $long, art: $withArtwork';

          Future<_CardRaster> render({bool changeLastRows = false}) async {
            final share = MusicLyricShare(
              lines: [
                if (long)
                  for (var i = 1; i < 30; i++) 'Verse $i'
                else
                  'Opening',
                if (long) 'A longer line that wraps across the image',
                changeLastRows ? 'Final' : 'End',
              ],
              attribution: 'Fixture song\nLong artist attribution\n'
                  'Lyrics source: LRCLIB\n'
                  '${changeLastRows ? 'User edited' : 'Edited'}',
              textDirection: direction,
            );
            final image = await share.image(
              sharePositionOrigin: origin,
              layout: layout,
              palette: palette,
              artwork: withArtwork ? artwork : null,
            );
            return _decodeCard(await image.files!.single.readAsBytes());
          }

          final card = await render();
          expect(card.width, 1080, reason: description);
          expect(card.height, inInclusiveRange(1, 2048), reason: description);
          final lyricBounds = card.inkBounds(lyricInk);
          final attributionBounds = card.inkBounds(attributionInk);
          for (final bounds in [lyricBounds, attributionBounds]) {
            expect(bounds.isEmpty, isFalse, reason: description);
            expect(bounds.left, greaterThan(0), reason: description);
            expect(bounds.right, lessThan(card.width), reason: description);
            expect(bounds.bottom, lessThan(card.height), reason: description);
          }
          expect(attributionBounds.top, greaterThan(lyricBounds.bottom),
              reason: description);

          final cover = card.inkBounds(fixtureArtworkColor);
          expect(cover.isEmpty, !withArtwork, reason: description);
          if (withArtwork) {
            switch (layout) {
              case MusicLyricShareLayout.classic:
                expect(cover.top, greaterThan(lyricBounds.bottom),
                    reason: description);
              case MusicLyricShareLayout.poster:
                expect(cover.bottom, lessThan(lyricBounds.top),
                    reason: description);
                expect(cover.center.dx, closeTo(card.width / 2, 1),
                    reason: description);
              case MusicLyricShareLayout.sideBySide:
                expect(cover.top, lessThan(lyricBounds.bottom),
                    reason: description);
                expect(
                  long
                      ? cover.left - lyricBounds.right
                      : lyricBounds.left - cover.right,
                  greaterThan(0),
                  reason: description,
                );
            }
          }

          if (long) {
            final changed = await render(changeLastRows: true);
            expect(changed.height, card.height, reason: description);
            expect(card.hasChangedInk(changed, lyricInk, lyricBounds), isTrue,
                reason: 'Final lyric is visible for $description');
            expect(
              card.hasChangedInk(changed, attributionInk, attributionBounds),
              isTrue,
              reason: 'Final attribution row is visible for $description',
            );
          }
        }
      }
    }
  });

  test('an oversized image can still be shared as text', () async {
    final lines = List.filled(100, 'Example lyric');
    final share = excerpt(lines);

    await expectLater(
      share.image(sharePositionOrigin: origin),
      throwsA(isA<StateError>()),
    );
    expect(
      share.text(sharePositionOrigin: origin).text,
      '${lines.join('\n')}\n\n$attribution',
    );
  });

  test('each palette keeps lyrics and attribution readable', () {
    for (final palette in MusicLyricSharePalette.values) {
      final background = palette.background.computeLuminance();
      for (final text in [palette.lyrics, palette.attribution]) {
        final luminance = text.computeLuminance();
        final (lighter, darker) = luminance > background
            ? (luminance, background)
            : (background, luminance);
        expect((lighter + 0.05) / (darker + 0.05), greaterThanOrEqualTo(4.5),
            reason: palette.name);
      }
    }
  });

  test('lyric card artwork follows the device cover source preference',
      () async {
    final owner = await SembastSqfDb.createInMemory();
    addTearDown(owner.close);
    final directory =
        Directory.systemTemp.createTempSync('videre-device-card-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final adjacent = File.fromUri(directory.uri.resolve('folder.png'))
      ..createSync();
    final embedded = File.fromUri(directory.uri.resolve('embedded.png'))
      ..createSync();
    final track = LocalMusicTrack(
      uri: 'content://documents/song',
      title: 'Device track',
      adjacentArtPath: adjacent.path,
      artPath: embedded.path,
    );
    final occurrence = localMusicPlaybackEntry(track, owner.profileId);

    Future<List<String>> artworkPaths() async {
      final files = await findMusicLyricShareArtwork(
        track: occurrence.musicMetadata!,
        video: null,
        offline: occurrence,
        localTrack: track,
        server: null,
        owner: owner,
        isCurrent: () => true,
      );
      return files.map((file) => file.path).toList();
    }

    expect(await artworkPaths(), [adjacent.path, embedded.path]);
    await DeviceMusicArtworkPreferences.setSource(
        owner, DeviceMusicArtworkSource.embeddedOnly);
    expect(await artworkPaths(), [embedded.path]);
  });

  testWidgets('layout and colors in the preview match the shared PNG',
      (tester) async {
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
    final directory = Directory.systemTemp.createTempSync('videre-lyric-card-');
    final messenger = tester.binding.defaultBinaryMessenger;
    final shares = <MethodCall>[];
    var temporaryDirectoryRequests = 0;
    messenger.setMockMethodCallHandler(pathProvider, (_) async {
      temporaryDirectoryRequests++;
      return directory.path;
    });
    messenger.setMockMethodCallHandler(shareChannel, (call) async {
      shares.add(call);
      return 'fixture-receiver';
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(pathProvider, null);
      messenger.setMockMethodCallHandler(shareChannel, null);
      directory.deleteSync(recursive: true);
    });

    final artworkFile = File('${directory.path}/fixture-cover.png');
    final corruptArtwork = File.fromUri(directory.uri.resolve('corrupt.png'))
      ..writeAsStringSync('unreadable artwork');
    await tester.runAsync(() async {
      final artwork = await _makeArtwork();
      try {
        final png = (await artwork.toByteData(format: ui.ImageByteFormat.png))!;
        artworkFile.writeAsBytesSync(
            png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
      } finally {
        artwork.dispose();
      }
    });

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: MusicLyricShareButton(
          lines: lyrics,
          track: const MusicMetadata(title: 'Fixture song', artist: 'Singer'),
          source: 'LRCLIB',
          edited: true,
          isCurrent: () => true,
          loadArtwork: () async => [corruptArtwork, artworkFile],
        ),
      ),
    ));
    final shareLines = find.byKey(const ValueKey('music-lyrics-share'));
    final paletteField =
        find.byType(DropdownButtonFormField<MusicLyricSharePalette>);
    final layoutField =
        find.byType(DropdownButtonFormField<MusicLyricShareLayout>);
    final shareImage = find.widgetWithText(FilledButton, 'Share image');
    final permission = find.byType(CheckboxListTile);
    final preview = find.byWidgetPredicate((widget) =>
        widget is Image && widget.semanticLabel == 'Lyric card preview');

    Future<void> waitFor(bool Function() ready, String description) async {
      final timer = Stopwatch()..start();
      while (!ready() && timer.elapsed < const Duration(seconds: 5)) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(ready(), isTrue, reason: description);
    }

    Future<Uint8List> previewAfter(Finder control) async {
      await tester.tap(control);
      await tester.pumpAndSettle();
      await waitFor(() => preview.evaluate().isNotEmpty, 'PNG preview');
      return (tester.widget<Image>(preview).image as MemoryImage).bytes;
    }

    final defaultPreview = await previewAfter(shareLines);
    await tester.tap(paletteField);
    await tester.pumpAndSettle();
    final palettePreview = await previewAfter(find.text('Parchment').last);
    await tester.tap(layoutField);
    await tester.pumpAndSettle();
    final selectedPreview = await previewAfter(find.text('Poster').last);
    expect(selectedPreview, isNot(equals(palettePreview)));
    expect(tester.widget<FilledButton>(shareImage).onPressed, isNull);
    expect(shares, isEmpty);
    expect(temporaryDirectoryRequests, 0);

    await tester.ensureVisible(permission);
    await tester.tap(permission);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(shareImage).onPressed, isNotNull);
    await tester.tap(shareImage);
    await waitFor(() => shares.isNotEmpty, 'native share method call');
    await tester.pumpAndSettle();

    expect(temporaryDirectoryRequests, 1);
    final call = shares.single;
    expect(call.method, 'share');
    final arguments = call.arguments as Map<Object?, Object?>;
    final paths = arguments['paths'] as List<Object?>;
    final file = File(paths.single! as String);
    final exported = file.readAsBytesSync();
    expect(exported, selectedPreview);
    final violet = (await tester.runAsync(() => _decodeCard(defaultPreview)))!;
    expect(violet.pixel(0, 0), 0x221733ff);
    expect(violet.inkBounds(0xbb9cf5ff).isEmpty, isFalse);
    final parchment = (await tester.runAsync(() => _decodeCard(exported)))!;
    expect(parchment.pixel(0, 0), 0xfff0d6ff);
    for (final color in [0xa74424ff, 0x361b12ff, 0x69432dff]) {
      expect(parchment.inkBounds(color).isEmpty, isFalse);
    }
    final art = parchment.inkBounds(fixtureArtworkColor);
    expect(art.isEmpty, isFalse);
    expect(art.bottom, lessThan(parchment.inkBounds(0x361b12ff).top));
  });
}

Future<ui.Image> _makeArtwork() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const Color(0xffe65309), BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(96, 72);
  } finally {
    picture.dispose();
  }
}

Future<_CardRaster> _decodeCard(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  try {
    final image = (await codec.getNextFrame()).image;
    try {
      final pixels = (await image.toByteData())!;
      return _CardRaster(image.width, image.height, pixels);
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

class _CardRaster {
  final int width;
  final int height;
  final ByteData pixels;

  _CardRaster(this.width, this.height, this.pixels);

  int pixel(int x, int y) => pixels.getUint32((y * width + x) * 4);

  Rect inkBounds(int color) {
    var left = width;
    var right = -1;
    var top = height;
    var bottom = -1;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (pixel(x, y) != color) continue;
        left = math.min(left, x);
        right = math.max(right, x);
        top = math.min(top, y);
        bottom = y;
      }
    }
    return right < 0
        ? Rect.zero
        : Rect.fromLTRB(
            left.toDouble(),
            top.toDouble(),
            (right + 1).toDouble(),
            (bottom + 1).toDouble(),
          );
  }

  bool hasChangedInk(_CardRaster other, int color, Rect bounds) {
    for (var y = bounds.top.toInt(); y < bounds.bottom.toInt(); y++) {
      for (var x = bounds.left.toInt(); x < bounds.right.toInt(); x++) {
        final before = pixel(x, y);
        final after = other.pixel(x, y);
        if (before != after && (before == color || after == color)) return true;
      }
    }
    return false;
  }
}
