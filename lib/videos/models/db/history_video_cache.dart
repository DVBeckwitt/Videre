import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:json_annotation/json_annotation.dart';

import '../../../globals.dart';
import '../../../utils/models/image_object.dart';

part 'history_video_cache.g.dart';

@JsonSerializable(explicitToJson: true)
class HistoryVideoCache {
  String title;
  String? author;
  String? authorId;
  int? lengthSeconds;
  // Preserve catalog artwork routing and reopen listened songs as Music.
  MusicMetadata? musicMetadata;

  String videoId;
  DateTime created = DateTime.now();

  String thumbnail;

  HistoryVideoCache(this.videoId, this.title, this.author, this.thumbnail,
      {this.authorId, this.lengthSeconds, this.musicMetadata});

  factory HistoryVideoCache.fromJson(Map<String, dynamic> json) =>
      _$HistoryVideoCacheFromJson(json);

  Map<String, dynamic> toJson() => _$HistoryVideoCacheToJson(this);

  Video toVideo() {
    return Video(
        title: title,
        videoId: videoId,
        author: author,
        authorId: authorId,
        lengthSeconds: lengthSeconds,
        musicMetadata: musicMetadata,
        videoThumbnails: [ImageObject("high", thumbnail, 1280, 720)]);
  }

  static Future<HistoryVideoCache> fromVideoIdToVideo(String e) async {
    final owner = db.forProfile(db.profileId);
    var cachedVideo = owner.getHistoryVideoByVideoId(e);
    if (cachedVideo == null) {
      final account = await owner.getCurrentlySelectedServer();
      final vid = await service.getVideo(e, serverOverride: account);
      cachedVideo = HistoryVideoCache(vid.videoId, vid.title ?? '', vid.author,
          ImageObject.getBestThumbnail(vid.videoThumbnails)?.url ?? '',
          authorId: vid.authorId,
          lengthSeconds: vid.lengthSeconds,
          musicMetadata: vid.musicMetadata);
      await owner.upsertHistoryVideo(cachedVideo);
    }
    return cachedVideo;
  }
}
