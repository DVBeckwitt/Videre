// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'downloaded_video.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ExportedMusicCopy _$ExportedMusicCopyFromJson(Map<String, dynamic> json) =>
    ExportedMusicCopy(
      json['folder'] as String,
      json['uri'] as String,
      $enumDecode(_$MusicDownloadFormatEnumMap, json['format']),
      complete: json['complete'] as bool? ?? false,
      editSignature: json['editSignature'] as String?,
      outputSha256: json['outputSha256'] as String?,
    );

Map<String, dynamic> _$ExportedMusicCopyToJson(ExportedMusicCopy instance) =>
    <String, dynamic>{
      'folder': instance.folder,
      'uri': instance.uri,
      'format': _$MusicDownloadFormatEnumMap[instance.format]!,
      'complete': instance.complete,
      'editSignature': instance.editSignature,
      'outputSha256': instance.outputSha256,
    };

const _$MusicDownloadFormatEnumMap = {
  MusicDownloadFormat.mp3: 'mp3',
  MusicDownloadFormat.opus: 'opus',
  MusicDownloadFormat.m4a: 'm4a',
};

_DownloadedVideo _$DownloadedVideoFromJson(Map<String, dynamic> json) =>
    _DownloadedVideo(
      videoId: json['videoId'] as String,
      title: json['title'] as String,
      profileId: json['profileId'] as String? ?? 'default',
      accountId: json['accountId'] as String?,
      author: json['author'] as String?,
      authorUrl: json['authorUrl'] as String?,
      musicMetadata: const _MusicMetadataConverter()
          .fromJson(json['musicMetadata'] as Map<String, dynamic>?),
      sponsorSegments: (json['sponsorSegments'] as List<dynamic>?)
              ?.map((e) => const _SponsorSegmentConverter()
                  .fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      downloadComplete: json['downloadComplete'] as bool? ?? false,
      downloadFailed: json['downloadFailed'] as bool? ?? false,
      authenticationRequired: json['authenticationRequired'] as bool? ?? false,
      storageFailed: json['storageFailed'] as bool? ?? false,
      folderUri: json['folderUri'] as String?,
      storageUri: json['storageUri'] as String?,
      playbackProvenance: const _PlaybackProvenanceConverter()
          .fromJson(json['playbackProvenance']),
      audioOnly: json['audioOnly'] as bool? ?? false,
      musicFormat: $enumDecodeNullable(
          _$MusicDownloadFormatEnumMap, json['musicFormat']),
      musicPolicy:
          const _MusicOfflinePolicyConverter().fromJson(json['musicPolicy']),
      exportedMusic: const _MusicCopyConverter()
          .fromJson(json['exportedMusic'] as Map<String, dynamic>?),
      editedMusicExport: const _MusicCopyConverter()
          .fromJson(json['editedMusicExport'] as Map<String, dynamic>?),
      pendingEditedMusicExport: const _MusicCopyConverter()
          .fromJson(json['pendingEditedMusicExport'] as Map<String, dynamic>?),
      container:
          $enumDecodeNullable(_$DownloadContainerEnumMap, json['container']),
      audioTrackId: json['audioTrackId'] as String?,
      captionLabel: json['captionLabel'] as String?,
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
      'musicMetadata':
          const _MusicMetadataConverter().toJson(instance.musicMetadata),
      'sponsorSegments': instance.sponsorSegments
          .map(const _SponsorSegmentConverter().toJson)
          .toList(),
      'downloadComplete': instance.downloadComplete,
      'downloadFailed': instance.downloadFailed,
      'authenticationRequired': instance.authenticationRequired,
      'storageFailed': instance.storageFailed,
      'folderUri': instance.folderUri,
      'storageUri': instance.storageUri,
      'playbackProvenance': const _PlaybackProvenanceConverter()
          .toJson(instance.playbackProvenance),
      'audioOnly': instance.audioOnly,
      'musicFormat': _$MusicDownloadFormatEnumMap[instance.musicFormat],
      'musicPolicy':
          const _MusicOfflinePolicyConverter().toJson(instance.musicPolicy),
      'exportedMusic':
          const _MusicCopyConverter().toJson(instance.exportedMusic),
      'editedMusicExport':
          const _MusicCopyConverter().toJson(instance.editedMusicExport),
      'pendingEditedMusicExport':
          const _MusicCopyConverter().toJson(instance.pendingEditedMusicExport),
      'container': _$DownloadContainerEnumMap[instance.container],
      'audioTrackId': instance.audioTrackId,
      'captionLabel': instance.captionLabel,
      'lengthSeconds': instance.lengthSeconds,
      'quality': instance.quality,
    };

const _$DownloadContainerEnumMap = {
  DownloadContainer.webm: 'webm',
  DownloadContainer.mp4: 'mp4',
};
