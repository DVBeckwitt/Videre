// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'add_server.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$AddServerState {
  bool get loading;
  bool get valid;
  bool get showAdvanced;
  bool get advancedTest;
  bool get protectedServer;
  String? get publicInstance;
  Map<String, String> get headers;

  /// Create a copy of AddServerState
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $AddServerStateCopyWith<AddServerState> get copyWith =>
      _$AddServerStateCopyWithImpl<AddServerState>(
          this as AddServerState, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is AddServerState &&
            (identical(other.loading, loading) || other.loading == loading) &&
            (identical(other.valid, valid) || other.valid == valid) &&
            (identical(other.showAdvanced, showAdvanced) ||
                other.showAdvanced == showAdvanced) &&
            (identical(other.advancedTest, advancedTest) ||
                other.advancedTest == advancedTest) &&
            (identical(other.protectedServer, protectedServer) ||
                other.protectedServer == protectedServer) &&
            (identical(other.publicInstance, publicInstance) ||
                other.publicInstance == publicInstance) &&
            const DeepCollectionEquality().equals(other.headers, headers));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      loading,
      valid,
      showAdvanced,
      advancedTest,
      protectedServer,
      publicInstance,
      const DeepCollectionEquality().hash(headers));

  @override
  String toString() {
    return 'AddServerState(loading: $loading, valid: $valid, showAdvanced: $showAdvanced, advancedTest: $advancedTest, protectedServer: $protectedServer, publicInstance: $publicInstance, headers: $headers)';
  }
}

/// @nodoc
abstract mixin class $AddServerStateCopyWith<$Res> {
  factory $AddServerStateCopyWith(
          AddServerState value, $Res Function(AddServerState) _then) =
      _$AddServerStateCopyWithImpl;
  @useResult
  $Res call(
      {bool loading,
      bool valid,
      bool showAdvanced,
      bool advancedTest,
      bool protectedServer,
      String? publicInstance,
      Map<String, String> headers});
}

/// @nodoc
class _$AddServerStateCopyWithImpl<$Res>
    implements $AddServerStateCopyWith<$Res> {
  _$AddServerStateCopyWithImpl(this._self, this._then);

  final AddServerState _self;
  final $Res Function(AddServerState) _then;

  /// Create a copy of AddServerState
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? loading = null,
    Object? valid = null,
    Object? showAdvanced = null,
    Object? advancedTest = null,
    Object? protectedServer = null,
    Object? publicInstance = freezed,
    Object? headers = null,
  }) {
    return _then(_self.copyWith(
      loading: null == loading
          ? _self.loading
          : loading // ignore: cast_nullable_to_non_nullable
              as bool,
      valid: null == valid
          ? _self.valid
          : valid // ignore: cast_nullable_to_non_nullable
              as bool,
      showAdvanced: null == showAdvanced
          ? _self.showAdvanced
          : showAdvanced // ignore: cast_nullable_to_non_nullable
              as bool,
      advancedTest: null == advancedTest
          ? _self.advancedTest
          : advancedTest // ignore: cast_nullable_to_non_nullable
              as bool,
      protectedServer: null == protectedServer
          ? _self.protectedServer
          : protectedServer // ignore: cast_nullable_to_non_nullable
              as bool,
      publicInstance: freezed == publicInstance
          ? _self.publicInstance
          : publicInstance // ignore: cast_nullable_to_non_nullable
              as String?,
      headers: null == headers
          ? _self.headers
          : headers // ignore: cast_nullable_to_non_nullable
              as Map<String, String>,
    ));
  }
}

/// @nodoc

class _AddServerState implements AddServerState {
  const _AddServerState(
      {this.loading = false,
      this.valid = false,
      this.showAdvanced = false,
      this.advancedTest = true,
      this.protectedServer = false,
      this.publicInstance,
      final Map<String, String> headers = const {}})
      : _headers = headers;

  @override
  @JsonKey()
  final bool loading;
  @override
  @JsonKey()
  final bool valid;
  @override
  @JsonKey()
  final bool showAdvanced;
  @override
  @JsonKey()
  final bool advancedTest;
  @override
  @JsonKey()
  final bool protectedServer;
  @override
  final String? publicInstance;
  final Map<String, String> _headers;
  @override
  @JsonKey()
  Map<String, String> get headers {
    if (_headers is EqualUnmodifiableMapView) return _headers;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(_headers);
  }

  /// Create a copy of AddServerState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$AddServerStateCopyWith<_AddServerState> get copyWith =>
      __$AddServerStateCopyWithImpl<_AddServerState>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _AddServerState &&
            (identical(other.loading, loading) || other.loading == loading) &&
            (identical(other.valid, valid) || other.valid == valid) &&
            (identical(other.showAdvanced, showAdvanced) ||
                other.showAdvanced == showAdvanced) &&
            (identical(other.advancedTest, advancedTest) ||
                other.advancedTest == advancedTest) &&
            (identical(other.protectedServer, protectedServer) ||
                other.protectedServer == protectedServer) &&
            (identical(other.publicInstance, publicInstance) ||
                other.publicInstance == publicInstance) &&
            const DeepCollectionEquality().equals(other._headers, _headers));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      loading,
      valid,
      showAdvanced,
      advancedTest,
      protectedServer,
      publicInstance,
      const DeepCollectionEquality().hash(_headers));

  @override
  String toString() {
    return 'AddServerState(loading: $loading, valid: $valid, showAdvanced: $showAdvanced, advancedTest: $advancedTest, protectedServer: $protectedServer, publicInstance: $publicInstance, headers: $headers)';
  }
}

/// @nodoc
abstract mixin class _$AddServerStateCopyWith<$Res>
    implements $AddServerStateCopyWith<$Res> {
  factory _$AddServerStateCopyWith(
          _AddServerState value, $Res Function(_AddServerState) _then) =
      __$AddServerStateCopyWithImpl;
  @override
  @useResult
  $Res call(
      {bool loading,
      bool valid,
      bool showAdvanced,
      bool advancedTest,
      bool protectedServer,
      String? publicInstance,
      Map<String, String> headers});
}

/// @nodoc
class __$AddServerStateCopyWithImpl<$Res>
    implements _$AddServerStateCopyWith<$Res> {
  __$AddServerStateCopyWithImpl(this._self, this._then);

  final _AddServerState _self;
  final $Res Function(_AddServerState) _then;

  /// Create a copy of AddServerState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? loading = null,
    Object? valid = null,
    Object? showAdvanced = null,
    Object? advancedTest = null,
    Object? protectedServer = null,
    Object? publicInstance = freezed,
    Object? headers = null,
  }) {
    return _then(_AddServerState(
      loading: null == loading
          ? _self.loading
          : loading // ignore: cast_nullable_to_non_nullable
              as bool,
      valid: null == valid
          ? _self.valid
          : valid // ignore: cast_nullable_to_non_nullable
              as bool,
      showAdvanced: null == showAdvanced
          ? _self.showAdvanced
          : showAdvanced // ignore: cast_nullable_to_non_nullable
              as bool,
      advancedTest: null == advancedTest
          ? _self.advancedTest
          : advancedTest // ignore: cast_nullable_to_non_nullable
              as bool,
      protectedServer: null == protectedServer
          ? _self.protectedServer
          : protectedServer // ignore: cast_nullable_to_non_nullable
              as bool,
      publicInstance: freezed == publicInstance
          ? _self.publicInstance
          : publicInstance // ignore: cast_nullable_to_non_nullable
              as String?,
      headers: null == headers
          ? _self._headers
          : headers // ignore: cast_nullable_to_non_nullable
              as Map<String, String>,
    ));
  }
}

// dart format on
