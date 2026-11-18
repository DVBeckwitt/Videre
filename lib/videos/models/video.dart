// ignore_for_file: invalid_annotation_target

import 'package:clipious/music/models/song_artwork.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/utils/models/sharelink.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import '../../utils/models/image_object.dart';
import 'adaptive_format.dart';
import 'caption.dart';
import 'format_stream.dart';
import 'music_metadata.dart';
import 'storyboard.dart';

part 'video.freezed.dart';
part 'video.g.dart';

/// Depending on versions, the published field can be a full formatted date or a timestamp
/// sometimes the published field is like this
///
///   "published": 1738022400,
///
/// sometimes it is:
///
///       "published": "2025-01-28T19:00:26Z",
int? _parsePublished(dynamic published) {
  if (published == null) return null;

  if (published is int) {
    return published;
  } else if (published is String) {
    try {
      return DateTime.parse(published).millisecondsSinceEpoch ~/ 1000;
    } catch (e) {
      return null;
    }
  }

  return null;
}

List<T>? _parseStreams<T>(
  Object? value,
  T Function(Map<String, dynamic>) parse,
) {
  if (value is! List) return null;

  final streams = <T>[];
  for (final item in value) {
    if (item is! Map) continue;
    try {
      streams.add(parse(Map<String, dynamic>.from(item)));
    } catch (_) {
      // One incomplete format must not make the whole video unplayable.
    }
  }
  return streams;
}

List<AdaptiveFormat>? _parseAdaptiveFormats(Object? value) =>
    _parseStreams(value, AdaptiveFormat.fromJson);

List<FormatStream>? _parseFormatStreams(Object? value) =>
    _parseStreams(value, FormatStream.fromJson);

@freezed
sealed class Video with _$Video implements ShareLinks, IdedVideo {
  @Implements<ShareLinks>()
  @Implements<IdedVideo>()
  const factory Video(
      {required String videoId,
      int? viewCount,
      @JsonKey(fromJson: _parsePublished) int? published,
      int? index,
      String? indexId,
      String? publishedText,
      bool? isUpcoming,
      int? premiereTimestamp,
      String? dashUrl,
      String? description,
      String? descriptionHtml,
      @Default([]) List<String> keywords,
      int? likeCount,
      int? dislikeCount,
      bool? paid,
      bool? premium,
      bool? isFamilyFriendly,
      @Default([]) List<String> allowedRegions,
      String? genre,
      String? genreUrl,
      @Default([]) List<ImageObject> authorThumbnails,
      String? subCountText,
      @Default(false) bool allowRatings,
      double? rating,
      bool? isListed,
      bool? liveNow,
      String? hlsUrl,
      @JsonKey(fromJson: _parseAdaptiveFormats)
      List<AdaptiveFormat>? adaptiveFormats,
      @JsonKey(fromJson: _parseFormatStreams) List<FormatStream>? formatStreams,
      @Default([]) List<Caption> captions,
      @JsonKey(fromJson: Storyboard.parseList)
      @Default([])
      List<Storyboard> storyboards,
      @Default([]) List<Video> recommendedVideos,
      String? title,
      int? lengthSeconds,
      String? author,
      String? authorId,
      String? authorUrl,
      @Default([]) List<ImageObject> videoThumbnails,
      MusicMetadata? musicMetadata,
      // Queue occurrences are local playback state, never Invidious metadata.
      @JsonKey(includeFromJson: false, includeToJson: false)
      String? queueEntryId,
      @JsonKey(includeFromJson: false, includeToJson: false)
      @Default(false)
      bool filtered,
      @JsonKey(includeFromJson: false, includeToJson: false)
      @Default([])
      List<VideoFilter> matchedFilters,
      @JsonKey(includeFromJson: false, includeToJson: false)
      @Default(false)
      bool filterHide,
      @JsonKey(includeFromJson: false, includeToJson: false)
      @Default(false)
      bool deArrowed,
      @JsonKey(includeFromJson: false, includeToJson: false)
      String? deArrowThumbnailUrl,
      @JsonKey(includeFromJson: false, includeToJson: false)
      BackendPlayback? backendPlayback,
      // Connection admission also applies to instances without backend selectors.
      @JsonKey(includeFromJson: false, includeToJson: false)
      BackendPlayback? playbackConnection,
      // Copies retain this token; fresh metadata creates a new native source.
      @JsonKey(includeFromJson: false, includeToJson: false)
      Object? playbackSourceId,
      // A verified saved rendition can start before online metadata exists.
      // The source cubit fetches real metadata lazily if local opening fails.
      @JsonKey(includeFromJson: false, includeToJson: false)
      @Default(false)
      bool downloadPlaybackOnly,
      String? viewCountText}) = _Video;

  const Video._();

  factory Video.fromJson(Map<String, Object?> json) =>
      _restoreMusicArtwork(_$VideoFromJson(json));

  static Video _restoreMusicArtwork(Video video) {
    final music = video.musicMetadata;
    if (music == null) return video;
    final restored =
        music.withoutVideoThumbnailFallbacks(video.videoThumbnails);
    return identical(music, restored)
        ? video
        : video.copyWith(musicMetadata: restored);
  }

  /// Stock Invidious has no Art Track flag. Require the Topic channel and
  /// both ends of the distributor-generated description on a Music video.
  /// Abbreviated search descriptions keep using ordinary upload artwork.
  bool get isStockArtTrack {
    if (genre?.trim().toLowerCase() != 'music' ||
        author?.trim().endsWith(' - Topic') != true ||
        liveNow == true ||
        isUpcoming == true) return false;
    final text = description?.trim();
    if (text == null || !text.startsWith('Provided to YouTube by '))
      return false;
    final firstBreak = text.indexOf('\n');
    if (firstBreak < 0 ||
        text
            .substring('Provided to YouTube by '.length, firstBreak)
            .trim()
            .isEmpty) {
      return false;
    }
    final footer = text.substring(text.lastIndexOf('\n') + 1).trim();
    return footer == 'Auto-generated by YouTube.' ||
        footer == 'Auto-generated by YouTube';
  }

  /// Known distributor descriptions place a single album line between the
  /// exact recording-title/artist credit and the copyright notice. If that
  /// layout changes, the stock poster remains available without an album label.
  String? get stockArtTrackAlbum {
    if (!isStockArtTrack) return null;
    final blocks =
        description!.trim().replaceAll('\r', '').split(RegExp(r'\n[ \t]*\n'));
    if (blocks.length < 5) return null;
    final credits = blocks[1].trim().split(' · ');
    final album = blocks[2].trim();
    if (credits.length < 2 ||
        credits.first != title?.trim() ||
        credits[1].trim().isEmpty ||
        album.isEmpty ||
        album.length > 256 ||
        album.contains('\n') ||
        !RegExp(r'^[℗©]').hasMatch(blocks[3].trim())) {
      return null;
    }
    return album;
  }

  /// Playback responses describe the upload; retain its queue occurrence and
  /// the song's catalog identity when fetching fresh stream URLs.
  Video preservingMusicMetadataFrom(Video source) {
    final music = source.musicMetadata;
    if (source.videoId != videoId) return this;
    if (music == null) {
      return queueEntryId == source.queueEntryId
          ? this
          : copyWith(queueEntryId: source.queueEntryId);
    }
    // A Takeout playlist can supply only the video ID. Use metadata from the
    // existing playback request to fill its placeholders before playing.
    final songTitle = music.title == videoId && title?.trim().isNotEmpty == true
        ? title!
        : music.title;
    final songArtist =
        music.artist.trim().isEmpty && author?.trim().isNotEmpty == true
            ? author!
            : music.artist;
    final artTrack = music.isArtTrack || isStockArtTrack;
    final album = music.album ?? stockArtTrackAlbum;
    final labels = songTitle == music.title &&
            songArtist == music.artist &&
            artTrack == music.isArtTrack &&
            album == music.album
        ? music
        : MusicMetadata(
            title: songTitle,
            artist: songArtist,
            album: album,
            thumbnails: music.thumbnails,
            isArtTrack: artTrack,
          );
    var frames = videoThumbnails;
    if (source.videoThumbnails.isNotEmpty) {
      final instanceUrl = (playbackConnection ?? backendPlayback)?.server.url;
      if (stockSongThumbnails(videoId, frames, instanceUrl: instanceUrl)
          .isEmpty) {
        final queuedFrames = stockSongThumbnails(
            videoId, source.videoThumbnails,
            instanceUrl: (source.playbackConnection ?? source.backendPlayback)
                    ?.server
                    .url ??
                instanceUrl);
        if (queuedFrames.isNotEmpty) {
          frames = queuedFrames;
        } else if (frames.isEmpty) {
          frames = source.videoThumbnails;
        }
      }
    }
    return copyWith(
      queueEntryId: source.queueEntryId,
      musicMetadata: labels,
      title: songTitle,
      author: songArtist,
      videoThumbnails: frames.isEmpty ? music.thumbnails : frames,
    );
  }

  @override
  Uri getInvidiousLink(Server server, int? timestamp) {
    return invidiousShareLink(server, pathSegments: [
      'watch'
    ], queryParameters: {
      'v': videoId,
      if (timestamp != null) 't': timestamp.toString(),
    });
  }

  @override
  Uri getYoutubeLink(int? timestamp) => Uri.https('www.youtube.com', '/watch', {
        'v': videoId,
        if (timestamp != null) 't': timestamp.toString(),
      });

  List<String> get thumbnails {
    return deArrowThumbnailUrl != null
        ? [deArrowThumbnailUrl!]
        : ImageObject.getThumbnailUrlsByPreferredOrder(videoThumbnails);
  }
}
