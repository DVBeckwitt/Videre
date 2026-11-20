// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'comments.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$CommentsState {
  Video get video;
  bool get loadingComments;
  String? get continuation;
  bool get continuationLoaded;
  VideoComments get comments;
  String get error;
  String? get source;
  String? get sortBy;

  /// Create a copy of CommentsState
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $CommentsStateCopyWith<CommentsState> get copyWith =>
      _$CommentsStateCopyWithImpl<CommentsState>(
          this as CommentsState, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is CommentsState &&
            (identical(other.video, video) || other.video == video) &&
            (identical(other.loadingComments, loadingComments) ||
                other.loadingComments == loadingComments) &&
            (identical(other.continuation, continuation) ||
                other.continuation == continuation) &&
            (identical(other.continuationLoaded, continuationLoaded) ||
                other.continuationLoaded == continuationLoaded) &&
            (identical(other.comments, comments) ||
                other.comments == comments) &&
            (identical(other.error, error) || other.error == error) &&
            (identical(other.source, source) || other.source == source) &&
            (identical(other.sortBy, sortBy) || other.sortBy == sortBy));
  }

  @override
  int get hashCode => Object.hash(runtimeType, video, loadingComments,
      continuation, continuationLoaded, comments, error, source, sortBy);

  @override
  String toString() {
    return 'CommentsState(video: $video, loadingComments: $loadingComments, continuation: $continuation, continuationLoaded: $continuationLoaded, comments: $comments, error: $error, source: $source, sortBy: $sortBy)';
  }
}

/// @nodoc
abstract mixin class $CommentsStateCopyWith<$Res> {
  factory $CommentsStateCopyWith(
          CommentsState value, $Res Function(CommentsState) _then) =
      _$CommentsStateCopyWithImpl;
  @useResult
  $Res call(
      {Video video,
      bool loadingComments,
      String? continuation,
      bool continuationLoaded,
      VideoComments comments,
      String error,
      String? source,
      String? sortBy});

  $VideoCopyWith<$Res> get video;
}

/// @nodoc
class _$CommentsStateCopyWithImpl<$Res>
    implements $CommentsStateCopyWith<$Res> {
  _$CommentsStateCopyWithImpl(this._self, this._then);

  final CommentsState _self;
  final $Res Function(CommentsState) _then;

  /// Create a copy of CommentsState
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? video = null,
    Object? loadingComments = null,
    Object? continuation = freezed,
    Object? continuationLoaded = null,
    Object? comments = null,
    Object? error = null,
    Object? source = freezed,
    Object? sortBy = freezed,
  }) {
    return _then(_self.copyWith(
      video: null == video
          ? _self.video
          : video // ignore: cast_nullable_to_non_nullable
              as Video,
      loadingComments: null == loadingComments
          ? _self.loadingComments
          : loadingComments // ignore: cast_nullable_to_non_nullable
              as bool,
      continuation: freezed == continuation
          ? _self.continuation
          : continuation // ignore: cast_nullable_to_non_nullable
              as String?,
      continuationLoaded: null == continuationLoaded
          ? _self.continuationLoaded
          : continuationLoaded // ignore: cast_nullable_to_non_nullable
              as bool,
      comments: null == comments
          ? _self.comments
          : comments // ignore: cast_nullable_to_non_nullable
              as VideoComments,
      error: null == error
          ? _self.error
          : error // ignore: cast_nullable_to_non_nullable
              as String,
      source: freezed == source
          ? _self.source
          : source // ignore: cast_nullable_to_non_nullable
              as String?,
      sortBy: freezed == sortBy
          ? _self.sortBy
          : sortBy // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }

  /// Create a copy of CommentsState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $VideoCopyWith<$Res> get video {
    return $VideoCopyWith<$Res>(_self.video, (value) {
      return _then(_self.copyWith(video: value));
    });
  }
}

/// @nodoc

class _CommentsState implements CommentsState {
  const _CommentsState(
      {required this.video,
      this.loadingComments = true,
      this.continuation,
      this.continuationLoaded = false,
      required this.comments,
      this.error = '',
      this.source,
      this.sortBy});

  @override
  final Video video;
  @override
  @JsonKey()
  final bool loadingComments;
  @override
  final String? continuation;
  @override
  @JsonKey()
  final bool continuationLoaded;
  @override
  final VideoComments comments;
  @override
  @JsonKey()
  final String error;
  @override
  final String? source;
  @override
  final String? sortBy;

  /// Create a copy of CommentsState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$CommentsStateCopyWith<_CommentsState> get copyWith =>
      __$CommentsStateCopyWithImpl<_CommentsState>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _CommentsState &&
            (identical(other.video, video) || other.video == video) &&
            (identical(other.loadingComments, loadingComments) ||
                other.loadingComments == loadingComments) &&
            (identical(other.continuation, continuation) ||
                other.continuation == continuation) &&
            (identical(other.continuationLoaded, continuationLoaded) ||
                other.continuationLoaded == continuationLoaded) &&
            (identical(other.comments, comments) ||
                other.comments == comments) &&
            (identical(other.error, error) || other.error == error) &&
            (identical(other.source, source) || other.source == source) &&
            (identical(other.sortBy, sortBy) || other.sortBy == sortBy));
  }

  @override
  int get hashCode => Object.hash(runtimeType, video, loadingComments,
      continuation, continuationLoaded, comments, error, source, sortBy);

  @override
  String toString() {
    return 'CommentsState(video: $video, loadingComments: $loadingComments, continuation: $continuation, continuationLoaded: $continuationLoaded, comments: $comments, error: $error, source: $source, sortBy: $sortBy)';
  }
}

/// @nodoc
abstract mixin class _$CommentsStateCopyWith<$Res>
    implements $CommentsStateCopyWith<$Res> {
  factory _$CommentsStateCopyWith(
          _CommentsState value, $Res Function(_CommentsState) _then) =
      __$CommentsStateCopyWithImpl;
  @override
  @useResult
  $Res call(
      {Video video,
      bool loadingComments,
      String? continuation,
      bool continuationLoaded,
      VideoComments comments,
      String error,
      String? source,
      String? sortBy});

  @override
  $VideoCopyWith<$Res> get video;
}

/// @nodoc
class __$CommentsStateCopyWithImpl<$Res>
    implements _$CommentsStateCopyWith<$Res> {
  __$CommentsStateCopyWithImpl(this._self, this._then);

  final _CommentsState _self;
  final $Res Function(_CommentsState) _then;

  /// Create a copy of CommentsState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? video = null,
    Object? loadingComments = null,
    Object? continuation = freezed,
    Object? continuationLoaded = null,
    Object? comments = null,
    Object? error = null,
    Object? source = freezed,
    Object? sortBy = freezed,
  }) {
    return _then(_CommentsState(
      video: null == video
          ? _self.video
          : video // ignore: cast_nullable_to_non_nullable
              as Video,
      loadingComments: null == loadingComments
          ? _self.loadingComments
          : loadingComments // ignore: cast_nullable_to_non_nullable
              as bool,
      continuation: freezed == continuation
          ? _self.continuation
          : continuation // ignore: cast_nullable_to_non_nullable
              as String?,
      continuationLoaded: null == continuationLoaded
          ? _self.continuationLoaded
          : continuationLoaded // ignore: cast_nullable_to_non_nullable
              as bool,
      comments: null == comments
          ? _self.comments
          : comments // ignore: cast_nullable_to_non_nullable
              as VideoComments,
      error: null == error
          ? _self.error
          : error // ignore: cast_nullable_to_non_nullable
              as String,
      source: freezed == source
          ? _self.source
          : source // ignore: cast_nullable_to_non_nullable
              as String?,
      sortBy: freezed == sortBy
          ? _self.sortBy
          : sortBy // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }

  /// Create a copy of CommentsState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $VideoCopyWith<$Res> get video {
    return $VideoCopyWith<$Res>(_self.video, (value) {
      return _then(_self.copyWith(video: value));
    });
  }
}

// dart format on
