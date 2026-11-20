// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'channel.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$ChannelController {
  String get channelId;
  Channel? get channel;
  bool get loading;
  bool get hasError;
  ChannelSortBy get sortBy;

  /// Create a copy of ChannelController
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $ChannelControllerCopyWith<ChannelController> get copyWith =>
      _$ChannelControllerCopyWithImpl<ChannelController>(
          this as ChannelController, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is ChannelController &&
            (identical(other.channelId, channelId) ||
                other.channelId == channelId) &&
            (identical(other.channel, channel) || other.channel == channel) &&
            (identical(other.loading, loading) || other.loading == loading) &&
            (identical(other.hasError, hasError) ||
                other.hasError == hasError) &&
            (identical(other.sortBy, sortBy) || other.sortBy == sortBy));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, channelId, channel, loading, hasError, sortBy);

  @override
  String toString() {
    return 'ChannelController(channelId: $channelId, channel: $channel, loading: $loading, hasError: $hasError, sortBy: $sortBy)';
  }
}

/// @nodoc
abstract mixin class $ChannelControllerCopyWith<$Res> {
  factory $ChannelControllerCopyWith(
          ChannelController value, $Res Function(ChannelController) _then) =
      _$ChannelControllerCopyWithImpl;
  @useResult
  $Res call(
      {String channelId,
      Channel? channel,
      bool loading,
      bool hasError,
      ChannelSortBy sortBy});
}

/// @nodoc
class _$ChannelControllerCopyWithImpl<$Res>
    implements $ChannelControllerCopyWith<$Res> {
  _$ChannelControllerCopyWithImpl(this._self, this._then);

  final ChannelController _self;
  final $Res Function(ChannelController) _then;

  /// Create a copy of ChannelController
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? channelId = null,
    Object? channel = freezed,
    Object? loading = null,
    Object? hasError = null,
    Object? sortBy = null,
  }) {
    return _then(_self.copyWith(
      channelId: null == channelId
          ? _self.channelId
          : channelId // ignore: cast_nullable_to_non_nullable
              as String,
      channel: freezed == channel
          ? _self.channel
          : channel // ignore: cast_nullable_to_non_nullable
              as Channel?,
      loading: null == loading
          ? _self.loading
          : loading // ignore: cast_nullable_to_non_nullable
              as bool,
      hasError: null == hasError
          ? _self.hasError
          : hasError // ignore: cast_nullable_to_non_nullable
              as bool,
      sortBy: null == sortBy
          ? _self.sortBy
          : sortBy // ignore: cast_nullable_to_non_nullable
              as ChannelSortBy,
    ));
  }
}

/// @nodoc

class _ChannelController implements ChannelController {
  const _ChannelController(
      {required this.channelId,
      this.channel,
      this.loading = true,
      this.hasError = false,
      this.sortBy = ChannelSortBy.newest});

  @override
  final String channelId;
  @override
  final Channel? channel;
  @override
  @JsonKey()
  final bool loading;
  @override
  @JsonKey()
  final bool hasError;
  @override
  @JsonKey()
  final ChannelSortBy sortBy;

  /// Create a copy of ChannelController
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$ChannelControllerCopyWith<_ChannelController> get copyWith =>
      __$ChannelControllerCopyWithImpl<_ChannelController>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _ChannelController &&
            (identical(other.channelId, channelId) ||
                other.channelId == channelId) &&
            (identical(other.channel, channel) || other.channel == channel) &&
            (identical(other.loading, loading) || other.loading == loading) &&
            (identical(other.hasError, hasError) ||
                other.hasError == hasError) &&
            (identical(other.sortBy, sortBy) || other.sortBy == sortBy));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, channelId, channel, loading, hasError, sortBy);

  @override
  String toString() {
    return 'ChannelController(channelId: $channelId, channel: $channel, loading: $loading, hasError: $hasError, sortBy: $sortBy)';
  }
}

/// @nodoc
abstract mixin class _$ChannelControllerCopyWith<$Res>
    implements $ChannelControllerCopyWith<$Res> {
  factory _$ChannelControllerCopyWith(
          _ChannelController value, $Res Function(_ChannelController) _then) =
      __$ChannelControllerCopyWithImpl;
  @override
  @useResult
  $Res call(
      {String channelId,
      Channel? channel,
      bool loading,
      bool hasError,
      ChannelSortBy sortBy});
}

/// @nodoc
class __$ChannelControllerCopyWithImpl<$Res>
    implements _$ChannelControllerCopyWith<$Res> {
  __$ChannelControllerCopyWithImpl(this._self, this._then);

  final _ChannelController _self;
  final $Res Function(_ChannelController) _then;

  /// Create a copy of ChannelController
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? channelId = null,
    Object? channel = freezed,
    Object? loading = null,
    Object? hasError = null,
    Object? sortBy = null,
  }) {
    return _then(_ChannelController(
      channelId: null == channelId
          ? _self.channelId
          : channelId // ignore: cast_nullable_to_non_nullable
              as String,
      channel: freezed == channel
          ? _self.channel
          : channel // ignore: cast_nullable_to_non_nullable
              as Channel?,
      loading: null == loading
          ? _self.loading
          : loading // ignore: cast_nullable_to_non_nullable
              as bool,
      hasError: null == hasError
          ? _self.hasError
          : hasError // ignore: cast_nullable_to_non_nullable
              as bool,
      sortBy: null == sortBy
          ? _self.sortBy
          : sortBy // ignore: cast_nullable_to_non_nullable
              as ChannelSortBy,
    ));
  }
}

// dart format on
