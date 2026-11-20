// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'compact_video.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$CompactVideoState {
  DownloadedVideo? get offlineVideo;
  String? get offlineVideoThumbnailPath;

  /// Create a copy of CompactVideoState
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $CompactVideoStateCopyWith<CompactVideoState> get copyWith =>
      _$CompactVideoStateCopyWithImpl<CompactVideoState>(
          this as CompactVideoState, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is CompactVideoState &&
            (identical(other.offlineVideo, offlineVideo) ||
                other.offlineVideo == offlineVideo) &&
            (identical(other.offlineVideoThumbnailPath,
                    offlineVideoThumbnailPath) ||
                other.offlineVideoThumbnailPath == offlineVideoThumbnailPath));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, offlineVideo, offlineVideoThumbnailPath);

  @override
  String toString() {
    return 'CompactVideoState(offlineVideo: $offlineVideo, offlineVideoThumbnailPath: $offlineVideoThumbnailPath)';
  }
}

/// @nodoc
abstract mixin class $CompactVideoStateCopyWith<$Res> {
  factory $CompactVideoStateCopyWith(
          CompactVideoState value, $Res Function(CompactVideoState) _then) =
      _$CompactVideoStateCopyWithImpl;
  @useResult
  $Res call({DownloadedVideo? offlineVideo, String? offlineVideoThumbnailPath});

  $DownloadedVideoCopyWith<$Res>? get offlineVideo;
}

/// @nodoc
class _$CompactVideoStateCopyWithImpl<$Res>
    implements $CompactVideoStateCopyWith<$Res> {
  _$CompactVideoStateCopyWithImpl(this._self, this._then);

  final CompactVideoState _self;
  final $Res Function(CompactVideoState) _then;

  /// Create a copy of CompactVideoState
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? offlineVideo = freezed,
    Object? offlineVideoThumbnailPath = freezed,
  }) {
    return _then(_self.copyWith(
      offlineVideo: freezed == offlineVideo
          ? _self.offlineVideo
          : offlineVideo // ignore: cast_nullable_to_non_nullable
              as DownloadedVideo?,
      offlineVideoThumbnailPath: freezed == offlineVideoThumbnailPath
          ? _self.offlineVideoThumbnailPath
          : offlineVideoThumbnailPath // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }

  /// Create a copy of CompactVideoState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $DownloadedVideoCopyWith<$Res>? get offlineVideo {
    if (_self.offlineVideo == null) {
      return null;
    }

    return $DownloadedVideoCopyWith<$Res>(_self.offlineVideo!, (value) {
      return _then(_self.copyWith(offlineVideo: value));
    });
  }
}

/// @nodoc

class _CompactVideoState implements CompactVideoState {
  const _CompactVideoState({this.offlineVideo, this.offlineVideoThumbnailPath});

  @override
  final DownloadedVideo? offlineVideo;
  @override
  final String? offlineVideoThumbnailPath;

  /// Create a copy of CompactVideoState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$CompactVideoStateCopyWith<_CompactVideoState> get copyWith =>
      __$CompactVideoStateCopyWithImpl<_CompactVideoState>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _CompactVideoState &&
            (identical(other.offlineVideo, offlineVideo) ||
                other.offlineVideo == offlineVideo) &&
            (identical(other.offlineVideoThumbnailPath,
                    offlineVideoThumbnailPath) ||
                other.offlineVideoThumbnailPath == offlineVideoThumbnailPath));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, offlineVideo, offlineVideoThumbnailPath);

  @override
  String toString() {
    return 'CompactVideoState(offlineVideo: $offlineVideo, offlineVideoThumbnailPath: $offlineVideoThumbnailPath)';
  }
}

/// @nodoc
abstract mixin class _$CompactVideoStateCopyWith<$Res>
    implements $CompactVideoStateCopyWith<$Res> {
  factory _$CompactVideoStateCopyWith(
          _CompactVideoState value, $Res Function(_CompactVideoState) _then) =
      __$CompactVideoStateCopyWithImpl;
  @override
  @useResult
  $Res call({DownloadedVideo? offlineVideo, String? offlineVideoThumbnailPath});

  @override
  $DownloadedVideoCopyWith<$Res>? get offlineVideo;
}

/// @nodoc
class __$CompactVideoStateCopyWithImpl<$Res>
    implements _$CompactVideoStateCopyWith<$Res> {
  __$CompactVideoStateCopyWithImpl(this._self, this._then);

  final _CompactVideoState _self;
  final $Res Function(_CompactVideoState) _then;

  /// Create a copy of CompactVideoState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? offlineVideo = freezed,
    Object? offlineVideoThumbnailPath = freezed,
  }) {
    return _then(_CompactVideoState(
      offlineVideo: freezed == offlineVideo
          ? _self.offlineVideo
          : offlineVideo // ignore: cast_nullable_to_non_nullable
              as DownloadedVideo?,
      offlineVideoThumbnailPath: freezed == offlineVideoThumbnailPath
          ? _self.offlineVideoThumbnailPath
          : offlineVideoThumbnailPath // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }

  /// Create a copy of CompactVideoState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $DownloadedVideoCopyWith<$Res>? get offlineVideo {
    if (_self.offlineVideo == null) {
      return null;
    }

    return $DownloadedVideoCopyWith<$Res>(_self.offlineVideo!, (value) {
      return _then(_self.copyWith(offlineVideo: value));
    });
  }
}

// dart format on
