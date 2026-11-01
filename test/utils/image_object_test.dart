import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/states/thumbnail.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ImageObject.getThumbnailUrlsForSize', () {
    final small = ImageObject('medium', '/small.jpg', 320, 180);
    final large = ImageObject('maxres', '/large.jpg', 1280, 720);
    final medium = ImageObject('sddefault', '/medium.jpg', 640, 480);

    test('uses the smallest source covering both physical dimensions', () {
      final images = [large, medium, small];
      expect(
          ImageObject.getThumbnailUrlsForSize(images, width: 320, height: 180),
          ['/small.jpg', '/large.jpg', '/medium.jpg']);
      expect(
          ImageObject.getThumbnailUrlsForSize(images, width: 640, height: 360),
          ['/medium.jpg', '/large.jpg', '/small.jpg']);
      expect(images, [large, medium, small]);
    });

    test('cover selection accounts for the short axis and retains fallbacks',
        () {
      final wide = ImageObject('medium', '/wide.jpg', 1000, 100);
      final square = ImageObject('default', '/square.jpg', 200, 200);
      final unknown = ImageObject(null, '/unknown.jpg', 0, 0);
      expect(
          ImageObject.getThumbnailUrlsForSize([wide, square, unknown],
              width: 150, height: 150),
          ['/square.jpg', '/wide.jpg', '/unknown.jpg']);
    });

    test('uses the largest available source when every candidate is too small',
        () {
      expect(
          ImageObject.getThumbnailUrlsForSize([small, medium, large],
              width: 2560, height: 1440),
          ['/large.jpg', '/medium.jpg', '/small.jpg']);
    });

    test('invalid constraints retain legacy selection', () {
      final images = [small, medium, large];
      final legacy = ImageObject.getThumbnailUrlsByPreferredOrder(images);
      for (final width in [0.0, -1.0, double.infinity, double.nan]) {
        expect(
            ImageObject.getThumbnailUrlsForSize(images,
                width: width, height: 180),
            legacy);
      }
      expect(ImageObject.getThumbnailUrlsForSize(null, width: 100, height: 100),
          isEmpty);
    });
  });

  group('ImageObject.getThumbnailUrlsByPreferredOrder', () {
    test('promotes exact maxres and preserves legacy fallback order', () {
      final images = [
        ImageObject('medium', '/medium.jpg', 320, 180),
        ImageObject('maxresdefault', '/maxresdefault.jpg', 1280, 720),
        ImageObject('maxres', '/maxres.jpg', 1280, 720),
        ImageObject('sddefault', '/sddefault.jpg', 640, 480),
      ];

      final urls = ImageObject.getThumbnailUrlsByPreferredOrder(images);

      expect(urls, [
        '/maxres.jpg',
        '/maxresdefault.jpg',
        '/sddefault.jpg',
        '/medium.jpg',
      ]);
    });

    test('keeps legacy ordering when exact maxres is absent', () {
      final images = [
        ImageObject(null, '/unknown-large.jpg', 1920, 1080),
        ImageObject('medium', '/medium.jpg', 320, 180),
        ImageObject('sddefault', '/sddefault.jpg', 640, 480),
        ImageObject('MAXRES', '/uppercase-maxres.jpg', 1280, 720),
        ImageObject('maxresdefault', '/maxresdefault.jpg', 1280, 720),
      ];

      final urls = ImageObject.getThumbnailUrlsByPreferredOrder(images);

      expect(urls, [
        '/maxresdefault.jpg',
        '/sddefault.jpg',
        '/unknown-large.jpg',
        '/uppercase-maxres.jpg',
        '/medium.jpg',
      ]);
    });

    test('does not mutate the caller list', () {
      final images = [
        ImageObject('medium', '/medium.jpg', 320, 180),
        ImageObject('maxres', '/maxres.jpg', 1280, 720),
        ImageObject('maxresdefault', '/maxresdefault.jpg', 1280, 720),
      ];
      final originalOrder = List<ImageObject>.from(images);

      ImageObject.getThumbnailUrlsByPreferredOrder(images);

      expect(images, orderedEquals(originalOrder));
    });

    test('keeps null and empty input behavior', () {
      expect(ImageObject.getThumbnailUrlsByPreferredOrder(null), isEmpty);
      expect(ImageObject.getThumbnailUrlsByPreferredOrder([]), isEmpty);
    });
  });

  test('getBestThumbnail keeps legacy default-first behavior', () {
    final maxres = ImageObject('maxres', '/maxres.jpg', 1280, 720);
    final maxresDefault =
        ImageObject('maxresdefault', '/maxresdefault.jpg', 1280, 720);

    final best = ImageObject.getBestThumbnail([maxres, maxresDefault]);

    expect(best, same(maxresDefault));
  });

  test('thumbnail failures try each fallback without changing the source list',
      () async {
    const urls = ['/maxres.jpg', '/medium.jpg'];
    final cubit = ThumbnailCubit(const ThumbnailState(urls: urls));
    expect(cubit.state.selected, urls.first);
    cubit.onThumbnailFailed();
    expect(cubit.state.selected, urls.last);
    cubit.onThumbnailFailed();
    expect(cubit.state.selected, isNull);
    expect(cubit.state.urls, isEmpty);
    expect(urls, hasLength(2));
    await cubit.close();
  });

  test('thumbnail failure arriving after disposal is ignored', () async {
    final cubit = ThumbnailCubit(
        const ThumbnailState(urls: ['/maxres.jpg', '/medium.jpg']));
    final lateImageError = cubit.onThumbnailFailed;
    final before = cubit.state;
    await cubit.close();
    expect(lateImageError, returnsNormally);
    expect(cubit.state, same(before));
  });
}
