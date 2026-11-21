// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'server.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$Server {
  String get url;
  String get profileId;
  String? get id;
  String get name;
  bool get gatewayEnabled;
  String? get authToken;
  String? get sidCookie;
  List<String> get mediaCompanionOrigins;
  Map<String, String>
      get customHeaders; // Freezed copies this parameter annotation to the generated field.
// ignore: invalid_annotation_target
  @JsonKey(
      fromJson: BackendSelector.tryFromJson,
      toJson: BackendSelector.optionalToJson)
  BackendSelector? get backendSelector;
  bool get inUse;

  /// Create a copy of Server
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $ServerCopyWith<Server> get copyWith =>
      _$ServerCopyWithImpl<Server>(this as Server, _$identity);

  /// Serializes this Server to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is Server &&
            (identical(other.url, url) || other.url == url) &&
            (identical(other.profileId, profileId) ||
                other.profileId == profileId) &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.name, name) || other.name == name) &&
            (identical(other.gatewayEnabled, gatewayEnabled) ||
                other.gatewayEnabled == gatewayEnabled) &&
            (identical(other.authToken, authToken) ||
                other.authToken == authToken) &&
            (identical(other.sidCookie, sidCookie) ||
                other.sidCookie == sidCookie) &&
            const DeepCollectionEquality()
                .equals(other.mediaCompanionOrigins, mediaCompanionOrigins) &&
            const DeepCollectionEquality()
                .equals(other.customHeaders, customHeaders) &&
            (identical(other.backendSelector, backendSelector) ||
                other.backendSelector == backendSelector) &&
            (identical(other.inUse, inUse) || other.inUse == inUse));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      url,
      profileId,
      id,
      name,
      gatewayEnabled,
      authToken,
      sidCookie,
      const DeepCollectionEquality().hash(mediaCompanionOrigins),
      const DeepCollectionEquality().hash(customHeaders),
      backendSelector,
      inUse);

  @override
  String toString() {
    return 'Server(url: $url, profileId: $profileId, id: $id, name: $name, gatewayEnabled: $gatewayEnabled, authToken: $authToken, sidCookie: $sidCookie, mediaCompanionOrigins: $mediaCompanionOrigins, customHeaders: $customHeaders, backendSelector: $backendSelector, inUse: $inUse)';
  }
}

/// @nodoc
abstract mixin class $ServerCopyWith<$Res> {
  factory $ServerCopyWith(Server value, $Res Function(Server) _then) =
      _$ServerCopyWithImpl;
  @useResult
  $Res call(
      {String url,
      String profileId,
      String? id,
      String name,
      bool gatewayEnabled,
      String? authToken,
      String? sidCookie,
      List<String> mediaCompanionOrigins,
      Map<String, String> customHeaders,
      @JsonKey(
          fromJson: BackendSelector.tryFromJson,
          toJson: BackendSelector.optionalToJson)
      BackendSelector? backendSelector,
      bool inUse});
}

/// @nodoc
class _$ServerCopyWithImpl<$Res> implements $ServerCopyWith<$Res> {
  _$ServerCopyWithImpl(this._self, this._then);

  final Server _self;
  final $Res Function(Server) _then;

  /// Create a copy of Server
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? url = null,
    Object? profileId = null,
    Object? id = freezed,
    Object? name = null,
    Object? gatewayEnabled = null,
    Object? authToken = freezed,
    Object? sidCookie = freezed,
    Object? mediaCompanionOrigins = null,
    Object? customHeaders = null,
    Object? backendSelector = freezed,
    Object? inUse = null,
  }) {
    return _then(_self.copyWith(
      url: null == url
          ? _self.url
          : url // ignore: cast_nullable_to_non_nullable
              as String,
      profileId: null == profileId
          ? _self.profileId
          : profileId // ignore: cast_nullable_to_non_nullable
              as String,
      id: freezed == id
          ? _self.id
          : id // ignore: cast_nullable_to_non_nullable
              as String?,
      name: null == name
          ? _self.name
          : name // ignore: cast_nullable_to_non_nullable
              as String,
      gatewayEnabled: null == gatewayEnabled
          ? _self.gatewayEnabled
          : gatewayEnabled // ignore: cast_nullable_to_non_nullable
              as bool,
      authToken: freezed == authToken
          ? _self.authToken
          : authToken // ignore: cast_nullable_to_non_nullable
              as String?,
      sidCookie: freezed == sidCookie
          ? _self.sidCookie
          : sidCookie // ignore: cast_nullable_to_non_nullable
              as String?,
      mediaCompanionOrigins: null == mediaCompanionOrigins
          ? _self.mediaCompanionOrigins
          : mediaCompanionOrigins // ignore: cast_nullable_to_non_nullable
              as List<String>,
      customHeaders: null == customHeaders
          ? _self.customHeaders
          : customHeaders // ignore: cast_nullable_to_non_nullable
              as Map<String, String>,
      backendSelector: freezed == backendSelector
          ? _self.backendSelector
          : backendSelector // ignore: cast_nullable_to_non_nullable
              as BackendSelector?,
      inUse: null == inUse
          ? _self.inUse
          : inUse // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _Server extends Server {
  const _Server(
      {required this.url,
      this.profileId = 'default',
      this.id,
      this.name = '',
      this.gatewayEnabled = false,
      this.authToken,
      this.sidCookie,
      final List<String> mediaCompanionOrigins = const [],
      final Map<String, String> customHeaders = const {},
      @JsonKey(
          fromJson: BackendSelector.tryFromJson,
          toJson: BackendSelector.optionalToJson)
      this.backendSelector,
      this.inUse = false})
      : _mediaCompanionOrigins = mediaCompanionOrigins,
        _customHeaders = customHeaders,
        super._();
  factory _Server.fromJson(Map<String, dynamic> json) => _$ServerFromJson(json);

  @override
  final String url;
  @override
  @JsonKey()
  final String profileId;
  @override
  final String? id;
  @override
  @JsonKey()
  final String name;
  @override
  @JsonKey()
  final bool gatewayEnabled;
  @override
  final String? authToken;
  @override
  final String? sidCookie;
  final List<String> _mediaCompanionOrigins;
  @override
  @JsonKey()
  List<String> get mediaCompanionOrigins {
    if (_mediaCompanionOrigins is EqualUnmodifiableListView)
      return _mediaCompanionOrigins;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_mediaCompanionOrigins);
  }

  final Map<String, String> _customHeaders;
  @override
  @JsonKey()
  Map<String, String> get customHeaders {
    if (_customHeaders is EqualUnmodifiableMapView) return _customHeaders;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(_customHeaders);
  }

// Freezed copies this parameter annotation to the generated field.
// ignore: invalid_annotation_target
  @override
  @JsonKey(
      fromJson: BackendSelector.tryFromJson,
      toJson: BackendSelector.optionalToJson)
  final BackendSelector? backendSelector;
  @override
  @JsonKey()
  final bool inUse;

  /// Create a copy of Server
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$ServerCopyWith<_Server> get copyWith =>
      __$ServerCopyWithImpl<_Server>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$ServerToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _Server &&
            (identical(other.url, url) || other.url == url) &&
            (identical(other.profileId, profileId) ||
                other.profileId == profileId) &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.name, name) || other.name == name) &&
            (identical(other.gatewayEnabled, gatewayEnabled) ||
                other.gatewayEnabled == gatewayEnabled) &&
            (identical(other.authToken, authToken) ||
                other.authToken == authToken) &&
            (identical(other.sidCookie, sidCookie) ||
                other.sidCookie == sidCookie) &&
            const DeepCollectionEquality()
                .equals(other._mediaCompanionOrigins, _mediaCompanionOrigins) &&
            const DeepCollectionEquality()
                .equals(other._customHeaders, _customHeaders) &&
            (identical(other.backendSelector, backendSelector) ||
                other.backendSelector == backendSelector) &&
            (identical(other.inUse, inUse) || other.inUse == inUse));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      url,
      profileId,
      id,
      name,
      gatewayEnabled,
      authToken,
      sidCookie,
      const DeepCollectionEquality().hash(_mediaCompanionOrigins),
      const DeepCollectionEquality().hash(_customHeaders),
      backendSelector,
      inUse);

  @override
  String toString() {
    return 'Server(url: $url, profileId: $profileId, id: $id, name: $name, gatewayEnabled: $gatewayEnabled, authToken: $authToken, sidCookie: $sidCookie, mediaCompanionOrigins: $mediaCompanionOrigins, customHeaders: $customHeaders, backendSelector: $backendSelector, inUse: $inUse)';
  }
}

/// @nodoc
abstract mixin class _$ServerCopyWith<$Res> implements $ServerCopyWith<$Res> {
  factory _$ServerCopyWith(_Server value, $Res Function(_Server) _then) =
      __$ServerCopyWithImpl;
  @override
  @useResult
  $Res call(
      {String url,
      String profileId,
      String? id,
      String name,
      bool gatewayEnabled,
      String? authToken,
      String? sidCookie,
      List<String> mediaCompanionOrigins,
      Map<String, String> customHeaders,
      @JsonKey(
          fromJson: BackendSelector.tryFromJson,
          toJson: BackendSelector.optionalToJson)
      BackendSelector? backendSelector,
      bool inUse});
}

/// @nodoc
class __$ServerCopyWithImpl<$Res> implements _$ServerCopyWith<$Res> {
  __$ServerCopyWithImpl(this._self, this._then);

  final _Server _self;
  final $Res Function(_Server) _then;

  /// Create a copy of Server
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? url = null,
    Object? profileId = null,
    Object? id = freezed,
    Object? name = null,
    Object? gatewayEnabled = null,
    Object? authToken = freezed,
    Object? sidCookie = freezed,
    Object? mediaCompanionOrigins = null,
    Object? customHeaders = null,
    Object? backendSelector = freezed,
    Object? inUse = null,
  }) {
    return _then(_Server(
      url: null == url
          ? _self.url
          : url // ignore: cast_nullable_to_non_nullable
              as String,
      profileId: null == profileId
          ? _self.profileId
          : profileId // ignore: cast_nullable_to_non_nullable
              as String,
      id: freezed == id
          ? _self.id
          : id // ignore: cast_nullable_to_non_nullable
              as String?,
      name: null == name
          ? _self.name
          : name // ignore: cast_nullable_to_non_nullable
              as String,
      gatewayEnabled: null == gatewayEnabled
          ? _self.gatewayEnabled
          : gatewayEnabled // ignore: cast_nullable_to_non_nullable
              as bool,
      authToken: freezed == authToken
          ? _self.authToken
          : authToken // ignore: cast_nullable_to_non_nullable
              as String?,
      sidCookie: freezed == sidCookie
          ? _self.sidCookie
          : sidCookie // ignore: cast_nullable_to_non_nullable
              as String?,
      mediaCompanionOrigins: null == mediaCompanionOrigins
          ? _self._mediaCompanionOrigins
          : mediaCompanionOrigins // ignore: cast_nullable_to_non_nullable
              as List<String>,
      customHeaders: null == customHeaders
          ? _self._customHeaders
          : customHeaders // ignore: cast_nullable_to_non_nullable
              as Map<String, String>,
      backendSelector: freezed == backendSelector
          ? _self.backendSelector
          : backendSelector // ignore: cast_nullable_to_non_nullable
              as BackendSelector?,
      inUse: null == inUse
          ? _self.inUse
          : inUse // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

// dart format on
