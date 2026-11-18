import 'dart:collection';

import 'package:json_annotation/json_annotation.dart';

part 'image_object.g.dart';

/// Thumbnail size selection stays within each group. A larger fallback
/// image shouldn't displace a preferred image before its request is tried.
class _ThumbnailFallbacks extends UnmodifiableListView<ImageObject> {
  final List<ImageObject> preferred;
  final List<ImageObject> fallback;

  _ThumbnailFallbacks(this.preferred, this.fallback)
      : super([...preferred, ...fallback]);
}

@JsonSerializable()
class ImageObject {
  String? quality;
  String url;
  int width;
  int height;

  ImageObject(this.quality, this.url, this.width, this.height);

  factory ImageObject.fromJson(Map<String, dynamic> json) =>
      _$ImageObjectFromJson(json);

  Map<String, dynamic> toJson() => _$ImageObjectToJson(this);

  static List<ImageObject> withFallback(
      List<ImageObject> preferred, List<ImageObject> fallback) {
    if (preferred.isEmpty) return fallback;
    if (fallback.isEmpty) return preferred;
    return _ThumbnailFallbacks(preferred, fallback);
  }

  static List<String> getThumbnailUrlsByPreferredOrder(
      List<ImageObject>? images) {
    if (images is _ThumbnailFallbacks) {
      return [
        ...getThumbnailUrlsByPreferredOrder(images.preferred),
        ...getThumbnailUrlsByPreferredOrder(images.fallback),
      ];
    }
    final thumbnails = _getThumbnailsByPreferredORder(images);
    final maxresIndex =
        thumbnails.indexWhere((thumbnail) => thumbnail.quality == 'maxres');

    if (maxresIndex > 0) {
      final maxres = thumbnails.removeAt(maxresIndex);
      thumbnails.insert(0, maxres);
    }

    return thumbnails.map((thumbnail) => thumbnail.url).toList();
  }

  /// Promotes the smallest source that covers the physical display size, while
  /// retaining the established fallback order and every supplied candidate.
  static List<String> getThumbnailUrlsForSize(List<ImageObject>? images,
      {required double width, required double height}) {
    if (images is _ThumbnailFallbacks) {
      return [
        ...getThumbnailUrlsForSize(images.preferred,
            width: width, height: height),
        ...getThumbnailUrlsForSize(images.fallback,
            width: width, height: height),
      ];
    }
    final urls = getThumbnailUrlsByPreferredOrder(images);
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return urls;
    }
    final candidates = (images ?? <ImageObject>[])
        .where((image) => image.width >= width && image.height >= height)
        .toList()
      ..sort((a, b) => (a.width * a.height).compareTo(b.width * b.height));
    if (candidates.isNotEmpty) {
      final preferred = candidates.first.url;
      urls.remove(preferred);
      urls.insert(0, preferred);
    }
    return urls;
  }

  static List<ImageObject> _getThumbnailsByPreferredORder(
      List<ImageObject>? images) {
    if (images != null && images.isNotEmpty) {
      List<ImageObject> imgs = List.from(images);
      imgs.sort((a, b) {
        final aHasDefault = a.quality?.contains("default") ?? false;
        final bHasDefault = b.quality?.contains("default") ?? false;

        if (bHasDefault == aHasDefault) {
          return (b.width * b.height).compareTo(a.width * a.height);
        } else {
          return (aHasDefault ? 0 : 1).compareTo(bHasDefault ? 0 : 1);
        }
      });
      return imgs;
    } else {
      return [];
    }
  }

  static ImageObject? getBestThumbnail(List<ImageObject>? images) =>
      images is _ThumbnailFallbacks
          ? getBestThumbnail(images.preferred)
          : _getThumbnailsByPreferredORder(images).firstOrNull;
}
