// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'thumbnail.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$ThumbnailState {
  List<String> get urls;
  String? get selected;

  /// Create a copy of ThumbnailState
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $ThumbnailStateCopyWith<ThumbnailState> get copyWith =>
      _$ThumbnailStateCopyWithImpl<ThumbnailState>(
          this as ThumbnailState, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is ThumbnailState &&
            const DeepCollectionEquality().equals(other.urls, urls) &&
            (identical(other.selected, selected) ||
                other.selected == selected));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType, const DeepCollectionEquality().hash(urls), selected);

  @override
  String toString() {
    return 'ThumbnailState(urls: $urls, selected: $selected)';
  }
}

/// @nodoc
abstract mixin class $ThumbnailStateCopyWith<$Res> {
  factory $ThumbnailStateCopyWith(
          ThumbnailState value, $Res Function(ThumbnailState) _then) =
      _$ThumbnailStateCopyWithImpl;
  @useResult
  $Res call({List<String> urls, String? selected});
}

/// @nodoc
class _$ThumbnailStateCopyWithImpl<$Res>
    implements $ThumbnailStateCopyWith<$Res> {
  _$ThumbnailStateCopyWithImpl(this._self, this._then);

  final ThumbnailState _self;
  final $Res Function(ThumbnailState) _then;

  /// Create a copy of ThumbnailState
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? urls = null,
    Object? selected = freezed,
  }) {
    return _then(_self.copyWith(
      urls: null == urls
          ? _self.urls
          : urls // ignore: cast_nullable_to_non_nullable
              as List<String>,
      selected: freezed == selected
          ? _self.selected
          : selected // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc

class _ThumbnailState implements ThumbnailState {
  const _ThumbnailState({final List<String> urls = const [], this.selected})
      : _urls = urls;

  final List<String> _urls;
  @override
  @JsonKey()
  List<String> get urls {
    if (_urls is EqualUnmodifiableListView) return _urls;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_urls);
  }

  @override
  final String? selected;

  /// Create a copy of ThumbnailState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$ThumbnailStateCopyWith<_ThumbnailState> get copyWith =>
      __$ThumbnailStateCopyWithImpl<_ThumbnailState>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _ThumbnailState &&
            const DeepCollectionEquality().equals(other._urls, _urls) &&
            (identical(other.selected, selected) ||
                other.selected == selected));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType, const DeepCollectionEquality().hash(_urls), selected);

  @override
  String toString() {
    return 'ThumbnailState(urls: $urls, selected: $selected)';
  }
}

/// @nodoc
abstract mixin class _$ThumbnailStateCopyWith<$Res>
    implements $ThumbnailStateCopyWith<$Res> {
  factory _$ThumbnailStateCopyWith(
          _ThumbnailState value, $Res Function(_ThumbnailState) _then) =
      __$ThumbnailStateCopyWithImpl;
  @override
  @useResult
  $Res call({List<String> urls, String? selected});
}

/// @nodoc
class __$ThumbnailStateCopyWithImpl<$Res>
    implements _$ThumbnailStateCopyWith<$Res> {
  __$ThumbnailStateCopyWithImpl(this._self, this._then);

  final _ThumbnailState _self;
  final $Res Function(_ThumbnailState) _then;

  /// Create a copy of ThumbnailState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? urls = null,
    Object? selected = freezed,
  }) {
    return _then(_ThumbnailState(
      urls: null == urls
          ? _self._urls
          : urls // ignore: cast_nullable_to_non_nullable
              as List<String>,
      selected: freezed == selected
          ? _self.selected
          : selected // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

// dart format on
