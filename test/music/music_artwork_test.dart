import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/music/views/components/music_catalog_cards.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/videos/views/components/video_thumbnail.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart' as cache;
import 'package:flutter_test/flutter_test.dart';

class _ArtworkCache extends Fake implements cache.BaseCacheManager {
  _ArtworkCache(this.file);

  final File file;
  final requests = <({String url, Map<String, String>? headers})>[];

  @override
  Stream<cache.FileResponse> getFileStream(String url,
      {String? key,
      Map<String, String>? headers,
      bool withProgress = false}) async* {
    requests.add((url: url, headers: headers));
    yield cache.FileInfo(file, cache.FileSource.Cache, DateTime.utc(2100), url);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sourceUrl = 'https://lh3.googleusercontent.com/album=w512-h512';
  const server = Server(
      url: 'https://instance.example',
      customHeaders: {'X-Test': 'music-artwork'});
  const boundaryKey = ValueKey('artwork-render');
  late File artwork;
  late cache.BaseCacheManager previousCache;
  late _ArtworkCache imageCache;

  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const Color(0xff14b45a), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(16, 16);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    artwork = MemoryFileSystem.test().file('album.png')
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
    // Avoid creating the plugin-backed default cache in this offline test isolate.
    CachedNetworkImageProvider.defaultCacheManager = _ArtworkCache(artwork);
  });

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    previousCache = CachedNetworkImageProvider.defaultCacheManager;
    imageCache = _ArtworkCache(artwork);
    CachedNetworkImageProvider.defaultCacheManager = imageCache;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  tearDown(() async {
    CachedNetworkImageProvider.defaultCacheManager = previousCache;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await db.close();
  });

  Widget card() => MusicCatalogCard(
        title: 'Album',
        subtitle: 'Artist',
        thumbnails: [ImageObject(null, sourceUrl, 512, 512)],
        onOpen: () {},
      );

  Widget thumbnail(String url, {bool useInvidiousProxy = false}) =>
      SizedBox.square(
        dimension: 56,
        child: Thumbnail(
          images: [ImageObject(null, url, 512, 512)],
          decoration: const BoxDecoration(),
          useInvidiousProxy: useInvidiousProxy,
        ),
      );

  Future<void> show(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RepaintBoundary(
          key: boundaryKey,
          child: SizedBox(
            width: 400,
            height: 400,
            child: Align(alignment: Alignment.topLeft, child: child),
          ),
        ),
      ),
    ));
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
  }

  Future<void> expectArtworkPixels(WidgetTester tester) async {
    final bounds = tester.getRect(find.byType(Thumbnail));
    expect(bounds.width, greaterThan(0));
    expect(bounds.height, greaterThan(0));
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
    final offset = bounds.topLeft - boundary.localToGlobal(Offset.zero);
    final pixels = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final colors = <List<int>>[];
      for (final fraction in [0.2, 0.5, 0.8]) {
        final x = (offset.dx + bounds.width * fraction).floor();
        final y = (offset.dy + bounds.height * fraction).floor();
        final index = (y * image.width + x) * 4;
        colors.add(
            List.generate(4, (channel) => bytes!.getUint8(index + channel)));
      }
      image.dispose();
      return colors;
    });
    expect(pixels, everyElement([20, 180, 90, 255]));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  }

  for (final (name, build) in <(String, Widget Function())>[
    (
      'shelf',
      () => MusicCatalogShelf(itemCount: 1, itemBuilder: (_, __) => card())
    ),
    (
      'grid',
      () => MusicCatalogGrid(itemCount: 1, itemBuilder: (_, __) => card())
    ),
    ('fixed artwork', () => thumbnail(sourceUrl)),
  ]) {
    for (final selectedServer in [false, true]) {
      testWidgets(
          '$name paints original Music artwork with selectedServer=$selectedServer',
          (tester) async {
        if (selectedServer) {
          await tester.runAsync(() async {
            await db.upsertServer(server);
            await db.useServer(server);
          });
        }
        try {
          await show(tester, build());
          expect(imageCache.requests, hasLength(1));
          expect(imageCache.requests.single.url, sourceUrl);
          expect(imageCache.requests.single.headers, isNull);
          await expectArtworkPixels(tester);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
        }
      });
    }
  }

  testWidgets('selected backend proxies artwork and supplies its headers',
      (tester) async {
    await tester.runAsync(() async {
      await db.upsertServer(server);
      await db.useServer(server);
    });
    try {
      await show(tester, thumbnail(sourceUrl, useInvidiousProxy: true));
      expect(imageCache.requests, hasLength(1));
      expect(imageCache.requests.single.url,
          'https://instance.example/ggpht/album=w512-h512');
      expect(imageCache.requests.single.headers,
          containsPair('X-Test', 'music-artwork'));
      await expectArtworkPixels(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('video cards prefer catalog art and retain the video fallback',
      (tester) async {
    const videoUrl = 'https://i.ytimg.com/vi/song/hqdefault.jpg';
    await tester.runAsync(() async {
      await db.upsertServer(server);
      await db.useServer(server);
    });
    try {
      await show(
          tester,
          VideoThumbnailView(
            videoId: 'song',
            thumbnails: const [videoUrl],
            images: [ImageObject(null, videoUrl, 480, 360)],
            musicThumbnails: [ImageObject(null, sourceUrl, 512, 512)],
          ));
      expect(imageCache.requests, hasLength(1));
      expect(imageCache.requests.single.url, sourceUrl);
      expect(imageCache.requests.single.headers, isNull);
      await expectArtworkPixels(tester);

      await show(
          tester,
          VideoThumbnailView(
            videoId: 'song',
            thumbnails: const [videoUrl],
            images: [ImageObject(null, videoUrl, 480, 360)],
            musicThumbnails: const [],
          ));
      expect(imageCache.requests, hasLength(2));
      expect(imageCache.requests.last.url,
          'https://instance.example/vi/song/hqdefault.jpg');
      expect(imageCache.requests.last.headers,
          containsPair('X-Test', 'music-artwork'));
      await expectArtworkPixels(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
      'relative artwork without a server fails without requesting a URL',
      (tester) async {
    try {
      await show(tester, thumbnail('/ggpht/album=w512-h512'));
      expect(imageCache.requests, isEmpty);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
