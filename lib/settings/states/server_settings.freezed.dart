// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'server_settings.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$ServerSettingsState {
  Server get server;
  bool get authenticating;
  bool get canDelete;

  /// Create a copy of ServerSettingsState
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $ServerSettingsStateCopyWith<ServerSettingsState> get copyWith =>
      _$ServerSettingsStateCopyWithImpl<ServerSettingsState>(
          this as ServerSettingsState, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is ServerSettingsState &&
            (identical(other.server, server) || other.server == server) &&
            (identical(other.authenticating, authenticating) ||
                other.authenticating == authenticating) &&
            (identical(other.canDelete, canDelete) ||
                other.canDelete == canDelete));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, server, authenticating, canDelete);

  @override
  String toString() {
    return 'ServerSettingsState(server: $server, authenticating: $authenticating, canDelete: $canDelete)';
  }
}

/// @nodoc
abstract mixin class $ServerSettingsStateCopyWith<$Res> {
  factory $ServerSettingsStateCopyWith(
          ServerSettingsState value, $Res Function(ServerSettingsState) _then) =
      _$ServerSettingsStateCopyWithImpl;
  @useResult
  $Res call({Server server, bool authenticating, bool canDelete});

  $ServerCopyWith<$Res> get server;
}

/// @nodoc
class _$ServerSettingsStateCopyWithImpl<$Res>
    implements $ServerSettingsStateCopyWith<$Res> {
  _$ServerSettingsStateCopyWithImpl(this._self, this._then);

  final ServerSettingsState _self;
  final $Res Function(ServerSettingsState) _then;

  /// Create a copy of ServerSettingsState
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? server = null,
    Object? authenticating = null,
    Object? canDelete = null,
  }) {
    return _then(_self.copyWith(
      server: null == server
          ? _self.server
          : server // ignore: cast_nullable_to_non_nullable
              as Server,
      authenticating: null == authenticating
          ? _self.authenticating
          : authenticating // ignore: cast_nullable_to_non_nullable
              as bool,
      canDelete: null == canDelete
          ? _self.canDelete
          : canDelete // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }

  /// Create a copy of ServerSettingsState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $ServerCopyWith<$Res> get server {
    return $ServerCopyWith<$Res>(_self.server, (value) {
      return _then(_self.copyWith(server: value));
    });
  }
}

/// @nodoc

class _ServerSettingsState extends ServerSettingsState {
  const _ServerSettingsState(
      {required this.server,
      this.authenticating = false,
      this.canDelete = false})
      : super._();

  @override
  final Server server;
  @override
  @JsonKey()
  final bool authenticating;
  @override
  @JsonKey()
  final bool canDelete;

  /// Create a copy of ServerSettingsState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$ServerSettingsStateCopyWith<_ServerSettingsState> get copyWith =>
      __$ServerSettingsStateCopyWithImpl<_ServerSettingsState>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _ServerSettingsState &&
            (identical(other.server, server) || other.server == server) &&
            (identical(other.authenticating, authenticating) ||
                other.authenticating == authenticating) &&
            (identical(other.canDelete, canDelete) ||
                other.canDelete == canDelete));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, server, authenticating, canDelete);

  @override
  String toString() {
    return 'ServerSettingsState(server: $server, authenticating: $authenticating, canDelete: $canDelete)';
  }
}

/// @nodoc
abstract mixin class _$ServerSettingsStateCopyWith<$Res>
    implements $ServerSettingsStateCopyWith<$Res> {
  factory _$ServerSettingsStateCopyWith(_ServerSettingsState value,
          $Res Function(_ServerSettingsState) _then) =
      __$ServerSettingsStateCopyWithImpl;
  @override
  @useResult
  $Res call({Server server, bool authenticating, bool canDelete});

  @override
  $ServerCopyWith<$Res> get server;
}

/// @nodoc
class __$ServerSettingsStateCopyWithImpl<$Res>
    implements _$ServerSettingsStateCopyWith<$Res> {
  __$ServerSettingsStateCopyWithImpl(this._self, this._then);

  final _ServerSettingsState _self;
  final $Res Function(_ServerSettingsState) _then;

  /// Create a copy of ServerSettingsState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? server = null,
    Object? authenticating = null,
    Object? canDelete = null,
  }) {
    return _then(_ServerSettingsState(
      server: null == server
          ? _self.server
          : server // ignore: cast_nullable_to_non_nullable
              as Server,
      authenticating: null == authenticating
          ? _self.authenticating
          : authenticating // ignore: cast_nullable_to_non_nullable
              as bool,
      canDelete: null == canDelete
          ? _self.canDelete
          : canDelete // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }

  /// Create a copy of ServerSettingsState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $ServerCopyWith<$Res> get server {
    return $ServerCopyWith<$Res>(_self.server, (value) {
      return _then(_self.copyWith(server: value));
    });
  }
}

// dart format on
