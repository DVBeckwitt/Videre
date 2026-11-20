// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'paginated_list_view.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$PaginatedListViewController<T> {
  PaginatedList<T> get paginatedList;
  List<T> get items;
  bool get hasError;
  bool get loading;

  /// Create a copy of PaginatedListViewController
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $PaginatedListViewControllerCopyWith<T, PaginatedListViewController<T>>
      get copyWith => _$PaginatedListViewControllerCopyWithImpl<T,
              PaginatedListViewController<T>>(
          this as PaginatedListViewController<T>, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is PaginatedListViewController<T> &&
            (identical(other.paginatedList, paginatedList) ||
                other.paginatedList == paginatedList) &&
            const DeepCollectionEquality().equals(other.items, items) &&
            (identical(other.hasError, hasError) ||
                other.hasError == hasError) &&
            (identical(other.loading, loading) || other.loading == loading));
  }

  @override
  int get hashCode => Object.hash(runtimeType, paginatedList,
      const DeepCollectionEquality().hash(items), hasError, loading);

  @override
  String toString() {
    return 'PaginatedListViewController<$T>(paginatedList: $paginatedList, items: $items, hasError: $hasError, loading: $loading)';
  }
}

/// @nodoc
abstract mixin class $PaginatedListViewControllerCopyWith<T, $Res> {
  factory $PaginatedListViewControllerCopyWith(
          PaginatedListViewController<T> value,
          $Res Function(PaginatedListViewController<T>) _then) =
      _$PaginatedListViewControllerCopyWithImpl;
  @useResult
  $Res call(
      {PaginatedList<T> paginatedList,
      List<T> items,
      bool hasError,
      bool loading});
}

/// @nodoc
class _$PaginatedListViewControllerCopyWithImpl<T, $Res>
    implements $PaginatedListViewControllerCopyWith<T, $Res> {
  _$PaginatedListViewControllerCopyWithImpl(this._self, this._then);

  final PaginatedListViewController<T> _self;
  final $Res Function(PaginatedListViewController<T>) _then;

  /// Create a copy of PaginatedListViewController
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? paginatedList = null,
    Object? items = null,
    Object? hasError = null,
    Object? loading = null,
  }) {
    return _then(_self.copyWith(
      paginatedList: null == paginatedList
          ? _self.paginatedList
          : paginatedList // ignore: cast_nullable_to_non_nullable
              as PaginatedList<T>,
      items: null == items
          ? _self.items
          : items // ignore: cast_nullable_to_non_nullable
              as List<T>,
      hasError: null == hasError
          ? _self.hasError
          : hasError // ignore: cast_nullable_to_non_nullable
              as bool,
      loading: null == loading
          ? _self.loading
          : loading // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class _PaginatedListViewController<T>
    implements PaginatedListViewController<T> {
  const _PaginatedListViewController(
      {required this.paginatedList,
      final List<T> items = const [],
      this.hasError = false,
      this.loading = false})
      : _items = items;

  @override
  final PaginatedList<T> paginatedList;
  final List<T> _items;
  @override
  @JsonKey()
  List<T> get items {
    if (_items is EqualUnmodifiableListView) return _items;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_items);
  }

  @override
  @JsonKey()
  final bool hasError;
  @override
  @JsonKey()
  final bool loading;

  /// Create a copy of PaginatedListViewController
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$PaginatedListViewControllerCopyWith<T, _PaginatedListViewController<T>>
      get copyWith => __$PaginatedListViewControllerCopyWithImpl<T,
          _PaginatedListViewController<T>>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _PaginatedListViewController<T> &&
            (identical(other.paginatedList, paginatedList) ||
                other.paginatedList == paginatedList) &&
            const DeepCollectionEquality().equals(other._items, _items) &&
            (identical(other.hasError, hasError) ||
                other.hasError == hasError) &&
            (identical(other.loading, loading) || other.loading == loading));
  }

  @override
  int get hashCode => Object.hash(runtimeType, paginatedList,
      const DeepCollectionEquality().hash(_items), hasError, loading);

  @override
  String toString() {
    return 'PaginatedListViewController<$T>(paginatedList: $paginatedList, items: $items, hasError: $hasError, loading: $loading)';
  }
}

/// @nodoc
abstract mixin class _$PaginatedListViewControllerCopyWith<T, $Res>
    implements $PaginatedListViewControllerCopyWith<T, $Res> {
  factory _$PaginatedListViewControllerCopyWith(
          _PaginatedListViewController<T> value,
          $Res Function(_PaginatedListViewController<T>) _then) =
      __$PaginatedListViewControllerCopyWithImpl;
  @override
  @useResult
  $Res call(
      {PaginatedList<T> paginatedList,
      List<T> items,
      bool hasError,
      bool loading});
}

/// @nodoc
class __$PaginatedListViewControllerCopyWithImpl<T, $Res>
    implements _$PaginatedListViewControllerCopyWith<T, $Res> {
  __$PaginatedListViewControllerCopyWithImpl(this._self, this._then);

  final _PaginatedListViewController<T> _self;
  final $Res Function(_PaginatedListViewController<T>) _then;

  /// Create a copy of PaginatedListViewController
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? paginatedList = null,
    Object? items = null,
    Object? hasError = null,
    Object? loading = null,
  }) {
    return _then(_PaginatedListViewController<T>(
      paginatedList: null == paginatedList
          ? _self.paginatedList
          : paginatedList // ignore: cast_nullable_to_non_nullable
              as PaginatedList<T>,
      items: null == items
          ? _self._items
          : items // ignore: cast_nullable_to_non_nullable
              as List<T>,
      hasError: null == hasError
          ? _self.hasError
          : hasError // ignore: cast_nullable_to_non_nullable
              as bool,
      loading: null == loading
          ? _self.loading
          : loading // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

// dart format on
