import 'package:clipious/videos/models/video.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import '../../utils/models/image_object.dart';

part 'playlist.freezed.dart';

part 'playlist.g.dart';

const youtubePlaylist = "youtubePlayList";
const invidiousPlaylist = "invidiousPlaylist";

@freezed
sealed class Playlist with _$Playlist {
  const factory Playlist(
      {@Default(youtubePlaylist) String type,
      required String title,
      required String playlistId,
      required String author,
      String? authordId,
      String? authorUrl,
      @Default([]) List<ImageObject> authorThumbnails,
      String? description,
      required int videoCount,
      int? viewCount,
      bool? isListed,
      int? updated,
      @Default([]) List<Video> videos,
      @JsonKey(includeToJson: false, includeFromJson: false)
      @Default(0)
      int removedByFilter}) = _Playlist;

  factory Playlist.fromJson(Map<String, Object?> json) =>
      _$PlaylistFromJson(json);
}
