import 'package:clipious/utils/models/image_object.dart';

class MusicPlaylist {
  final String id;
  final String title;
  final String? author;
  final List<ImageObject> thumbnails;

  const MusicPlaylist({
    required this.id,
    required this.title,
    this.author,
    this.thumbnails = const [],
  });
}
