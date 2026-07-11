import 'package:clipious/utils/models/image_object.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
