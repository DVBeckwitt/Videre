// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'progress.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Progress _$ProgressFromJson(Map<String, dynamic> json) => Progress(
      (json['progress'] as num).toDouble(),
      json['videoId'] as String,
      positionSeconds: (json['positionSeconds'] as num?)?.toInt(),
      durationSeconds: (json['durationSeconds'] as num?)?.toInt(),
    );
