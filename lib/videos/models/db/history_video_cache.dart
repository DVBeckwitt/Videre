import 'package:clipious/videos/models/video.dart';
import 'package:json_annotation/json_annotation.dart';

import '../../../globals.dart';
import '../../../utils/models/image_object.dart';

part 'history_video_cache.g.dart';

@JsonSerializable()
class HistoryVideoCache {
  String title;
  String? author;
  String? authorId;
  int? lengthSeconds;

  String videoId;
  DateTime created = DateTime.now();

  String thumbnail;

  HistoryVideoCache(this.videoId, this.title, this.author, this.thumbnail,
      {this.authorId, this.lengthSeconds});

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
        videoThumbnails: [ImageObject("high", thumbnail, 1280, 720)]);
  }

  static Future<HistoryVideoCache> fromVideoIdToVideo(String e) async {
    var cachedVideo = db.getHistoryVideoByVideoId(e);
    if (cachedVideo == null) {
      var vid = await service.getVideo(e);
      cachedVideo = HistoryVideoCache(vid.videoId, vid.title ?? '', vid.author,
          ImageObject.getBestThumbnail(vid.videoThumbnails)?.url ?? '',
          authorId: vid.authorId, lengthSeconds: vid.lengthSeconds);
      await db.upsertHistoryVideo(cachedVideo);
    }
    return cachedVideo;
  }
}
