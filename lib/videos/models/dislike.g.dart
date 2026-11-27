// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'dislike.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Dislike _$DislikeFromJson(Map<String, dynamic> json) => Dislike(
      Dislike._parseDislikes(json['dislikes']),
      likes: Dislike._parseLikes(json['likes']),
    );

Map<String, dynamic> _$DislikeToJson(Dislike instance) => <String, dynamic>{
      'dislikes': instance.dislikes,
      'likes': instance.likes,
    };
