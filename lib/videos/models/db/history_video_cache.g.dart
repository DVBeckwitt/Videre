// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'history_video_cache.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

HistoryVideoCache _$HistoryVideoCacheFromJson(Map<String, dynamic> json) =>
    HistoryVideoCache(
      json['videoId'] as String,
      json['title'] as String,
      json['author'] as String?,
      json['thumbnail'] as String,
      authorId: json['authorId'] as String?,
      lengthSeconds: (json['lengthSeconds'] as num?)?.toInt(),
      musicMetadata: json['musicMetadata'] == null
          ? null
          : MusicMetadata.fromJson(
              json['musicMetadata'] as Map<String, dynamic>),
    )..created = DateTime.parse(json['created'] as String);

Map<String, dynamic> _$HistoryVideoCacheToJson(HistoryVideoCache instance) =>
    <String, dynamic>{
      'title': instance.title,
      'author': instance.author,
      'authorId': instance.authorId,
      'lengthSeconds': instance.lengthSeconds,
      'musicMetadata': instance.musicMetadata?.toJson(),
      'videoId': instance.videoId,
      'created': instance.created.toIso8601String(),
      'thumbnail': instance.thumbnail,
    };
