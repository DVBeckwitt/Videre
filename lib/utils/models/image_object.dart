import 'package:json_annotation/json_annotation.dart';

part 'image_object.g.dart';

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

  static List<String> getThumbnailUrlsByPreferredOrder(
      List<ImageObject>? images) {
    final thumbnails = _getThumbnailsByPreferredORder(images);
    final maxresIndex =
        thumbnails.indexWhere((thumbnail) => thumbnail.quality == 'maxres');

    if (maxresIndex > 0) {
      final maxres = thumbnails.removeAt(maxresIndex);
      thumbnails.insert(0, maxres);
    }

    return thumbnails.map((thumbnail) => thumbnail.url).toList();
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

  static ImageObject? getBestThumbnail(List<ImageObject>? images) {
    final imgs = _getThumbnailsByPreferredORder(images);
    if (imgs.isNotEmpty) {
      return imgs.firstOrNull;
    } else {
      return null;
    }
  }

  static ImageObject? getWorstThumbnail(List<ImageObject>? images) {
    if (images != null && images.isNotEmpty) {
      List<ImageObject> imgs = List.from(images);
      imgs.sort((a, b) {
        return (a.width * a.height).compareTo(b.width * b.height);
      });

      return imgs[0];
    } else {
      return null;
    }
  }
}
