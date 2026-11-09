import 'package:clipious/utils/models/image_object.dart';

class MusicArtist {
  final String id;
  final String name;
  final List<ImageObject> thumbnails;

  const MusicArtist({
    required this.id,
    required this.name,
    this.thumbnails = const [],
  });
}
