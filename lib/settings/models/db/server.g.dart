// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'server.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Server _$ServerFromJson(Map<String, dynamic> json) => _Server(
      url: json['url'] as String,
      profileId: json['profileId'] as String? ?? 'default',
      id: json['id'] as String?,
      name: json['name'] as String? ?? '',
      gatewayEnabled: json['gatewayEnabled'] as bool? ?? false,
      authToken: json['authToken'] as String?,
      sidCookie: json['sidCookie'] as String?,
      customHeaders: (json['customHeaders'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(k, e as String),
          ) ??
          const {},
      backendSelector: BackendSelector.tryFromJson(json['backendSelector']),
      inUse: json['inUse'] as bool? ?? false,
    );

Map<String, dynamic> _$ServerToJson(_Server instance) => <String, dynamic>{
      'url': instance.url,
      'profileId': instance.profileId,
      'id': instance.id,
      'name': instance.name,
      'gatewayEnabled': instance.gatewayEnabled,
      'authToken': instance.authToken,
      'sidCookie': instance.sidCookie,
      'customHeaders': instance.customHeaders,
      'backendSelector':
          BackendSelector.optionalToJson(instance.backendSelector),
      'inUse': instance.inUse,
    };
