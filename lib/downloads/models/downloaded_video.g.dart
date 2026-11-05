// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'downloaded_video.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_DownloadedVideo _$DownloadedVideoFromJson(Map<String, dynamic> json) =>
    _DownloadedVideo(
      videoId: json['videoId'] as String,
      title: json['title'] as String,
      profileId: json['profileId'] as String? ?? 'default',
      accountId: json['accountId'] as String?,
      author: json['author'] as String?,
      authorUrl: json['authorUrl'] as String?,
      downloadComplete: json['downloadComplete'] as bool? ?? false,
      downloadFailed: json['downloadFailed'] as bool? ?? false,
      authenticationRequired: json['authenticationRequired'] as bool? ?? false,
      storageFailed: json['storageFailed'] as bool? ?? false,
      folderUri: json['folderUri'] as String?,
      storageUri: json['storageUri'] as String?,
      audioOnly: json['audioOnly'] as bool? ?? false,
      container:
          $enumDecodeNullable(_$DownloadContainerEnumMap, json['container']),
      lengthSeconds: (json['lengthSeconds'] as num).toInt(),
      quality: json['quality'] as String,
    );

Map<String, dynamic> _$DownloadedVideoToJson(_DownloadedVideo instance) =>
    <String, dynamic>{
      'videoId': instance.videoId,
      'title': instance.title,
      'profileId': instance.profileId,
      'accountId': instance.accountId,
      'author': instance.author,
      'authorUrl': instance.authorUrl,
      'downloadComplete': instance.downloadComplete,
      'downloadFailed': instance.downloadFailed,
      'authenticationRequired': instance.authenticationRequired,
      'storageFailed': instance.storageFailed,
      'folderUri': instance.folderUri,
      'storageUri': instance.storageUri,
      'audioOnly': instance.audioOnly,
      'container': _$DownloadContainerEnumMap[instance.container],
      'lengthSeconds': instance.lengthSeconds,
      'quality': instance.quality,
    };

const _$DownloadContainerEnumMap = {
  DownloadContainer.webm: 'webm',
  DownloadContainer.mp4: 'mp4',
};
