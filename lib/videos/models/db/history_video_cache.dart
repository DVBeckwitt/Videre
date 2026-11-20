import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:json_annotation/json_annotation.dart';

import '../../../globals.dart';
import '../../../utils/models/image_object.dart';

part 'history_video_cache.g.dart';

/// The Videre section in which a playback entry was selected.
enum PlaybackHistoryOrigin { video, music }

/// A pending play may fill its history row once, unless a later edit cancels it.
class PlaybackHistoryWrite {
  final String profileId;
  final PlaybackHistoryOrigin origin;
  final String videoId;
  final Future<void> Function(HistoryVideoCache, bool Function()) _store;
  final void Function(PlaybackHistoryWrite)? _onFinish;
  bool _cancelled = false;
  bool _started = false;

  PlaybackHistoryWrite(this.profileId, this.origin, this.videoId, this._store,
      {void Function(PlaybackHistoryWrite)? onFinish})
      : _onFinish = onFinish;

  Future<void> record(HistoryVideoCache entry) async {
    if (_cancelled || _started) return;
    _started = true;
    try {
      if (entry.videoId != videoId) {
        throw ArgumentError('Playback history belongs to another video.');
      }
      await _store(entry, () => !_cancelled);
    } finally {
      cancel();
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onFinish?.call(this);
  }
}

@JsonSerializable(explicitToJson: true)
class HistoryVideoCache {
  String title;
  String? author;
  String? authorId;
  int? lengthSeconds;
  // Preserve catalog artwork routing and reopen listened songs as Music.
  MusicMetadata? musicMetadata;

  final bool playedFromDownload;
  final String? downloadAccountId;
  @JsonKey(includeFromJson: false, includeToJson: false)
  PlaybackHistoryOrigin? origin;

  String videoId;
  DateTime created = DateTime.now();

  String thumbnail;

  HistoryVideoCache(this.videoId, this.title, this.author, this.thumbnail,
      {this.authorId,
      this.lengthSeconds,
      this.musicMetadata,
      this.playedFromDownload = false,
      this.downloadAccountId});

  factory HistoryVideoCache.fromJson(Map<String, dynamic> json) =>
      _$HistoryVideoCacheFromJson(json);

  Map<String, dynamic> toJson() {
    final row = _$HistoryVideoCacheToJson(this);
    if (!playedFromDownload) {
      row.remove('playedFromDownload');
      row.remove('downloadAccountId');
    }
    return row;
  }

  /// An explicit offline play can reopen the same profile's saved rendition,
  /// including older downloads which have no online substitution provenance.
  DownloadedVideo? replayDownload(IDbClient database) {
    if (!playedFromDownload) return null;
    final saved = database.getDownloadByVideoId(videoId);
    if (saved == null ||
        saved.profileId != database.profileId ||
        saved.accountId != downloadAccountId ||
        !saved.downloadComplete ||
        saved.downloadFailed ||
        saved.storageFailed ||
        saved.authenticationRequired) {
      return null;
    }
    return saved;
  }

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

  static Future<HistoryVideoCache> fromVideoIdToVideo(String e,
      {bool cacheFetched = true}) async {
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
      if (cacheFetched) await owner.upsertHistoryVideo(cachedVideo);
    }
    return cachedVideo;
  }
}
