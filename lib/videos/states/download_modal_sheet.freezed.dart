// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'download_modal_sheet.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$DownloadModalSheetState {
  bool get audioOnly;
  bool get loading;
  bool get failed;
  bool get audioTrackDiscoveryFailed;
  List<AdaptiveFormat> get availableQualities;
  List<DownloadContainer> get availableContainers;
  List<AudioTrack> get audioTracks;
  List<Caption> get captions;
  DownloadContainer? get container;
  String? get audioTrackId;
  String? get captionLabel;
  String get quality;

  /// Create a copy of DownloadModalSheetState
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $DownloadModalSheetStateCopyWith<DownloadModalSheetState> get copyWith =>
      _$DownloadModalSheetStateCopyWithImpl<DownloadModalSheetState>(
          this as DownloadModalSheetState, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is DownloadModalSheetState &&
            (identical(other.audioOnly, audioOnly) ||
                other.audioOnly == audioOnly) &&
            (identical(other.loading, loading) || other.loading == loading) &&
            (identical(other.failed, failed) || other.failed == failed) &&
            (identical(other.audioTrackDiscoveryFailed,
                    audioTrackDiscoveryFailed) ||
                other.audioTrackDiscoveryFailed == audioTrackDiscoveryFailed) &&
            const DeepCollectionEquality()
                .equals(other.availableQualities, availableQualities) &&
            const DeepCollectionEquality()
                .equals(other.availableContainers, availableContainers) &&
            const DeepCollectionEquality()
                .equals(other.audioTracks, audioTracks) &&
            const DeepCollectionEquality().equals(other.captions, captions) &&
            (identical(other.container, container) ||
                other.container == container) &&
            (identical(other.audioTrackId, audioTrackId) ||
                other.audioTrackId == audioTrackId) &&
            (identical(other.captionLabel, captionLabel) ||
                other.captionLabel == captionLabel) &&
            (identical(other.quality, quality) || other.quality == quality));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      audioOnly,
      loading,
      failed,
      audioTrackDiscoveryFailed,
      const DeepCollectionEquality().hash(availableQualities),
      const DeepCollectionEquality().hash(availableContainers),
      const DeepCollectionEquality().hash(audioTracks),
      const DeepCollectionEquality().hash(captions),
      container,
      audioTrackId,
      captionLabel,
      quality);

  @override
  String toString() {
    return 'DownloadModalSheetState(audioOnly: $audioOnly, loading: $loading, failed: $failed, audioTrackDiscoveryFailed: $audioTrackDiscoveryFailed, availableQualities: $availableQualities, availableContainers: $availableContainers, audioTracks: $audioTracks, captions: $captions, container: $container, audioTrackId: $audioTrackId, captionLabel: $captionLabel, quality: $quality)';
  }
}

/// @nodoc
abstract mixin class $DownloadModalSheetStateCopyWith<$Res> {
  factory $DownloadModalSheetStateCopyWith(DownloadModalSheetState value,
          $Res Function(DownloadModalSheetState) _then) =
      _$DownloadModalSheetStateCopyWithImpl;
  @useResult
  $Res call(
      {bool audioOnly,
      bool loading,
      bool failed,
      bool audioTrackDiscoveryFailed,
      List<AdaptiveFormat> availableQualities,
      List<DownloadContainer> availableContainers,
      List<AudioTrack> audioTracks,
      List<Caption> captions,
      DownloadContainer? container,
      String? audioTrackId,
      String? captionLabel,
      String quality});
}

/// @nodoc
class _$DownloadModalSheetStateCopyWithImpl<$Res>
    implements $DownloadModalSheetStateCopyWith<$Res> {
  _$DownloadModalSheetStateCopyWithImpl(this._self, this._then);

  final DownloadModalSheetState _self;
  final $Res Function(DownloadModalSheetState) _then;

  /// Create a copy of DownloadModalSheetState
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? audioOnly = null,
    Object? loading = null,
    Object? failed = null,
    Object? audioTrackDiscoveryFailed = null,
    Object? availableQualities = null,
    Object? availableContainers = null,
    Object? audioTracks = null,
    Object? captions = null,
    Object? container = freezed,
    Object? audioTrackId = freezed,
    Object? captionLabel = freezed,
    Object? quality = null,
  }) {
    return _then(_self.copyWith(
      audioOnly: null == audioOnly
          ? _self.audioOnly
          : audioOnly // ignore: cast_nullable_to_non_nullable
              as bool,
      loading: null == loading
          ? _self.loading
          : loading // ignore: cast_nullable_to_non_nullable
              as bool,
      failed: null == failed
          ? _self.failed
          : failed // ignore: cast_nullable_to_non_nullable
              as bool,
      audioTrackDiscoveryFailed: null == audioTrackDiscoveryFailed
          ? _self.audioTrackDiscoveryFailed
          : audioTrackDiscoveryFailed // ignore: cast_nullable_to_non_nullable
              as bool,
      availableQualities: null == availableQualities
          ? _self.availableQualities
          : availableQualities // ignore: cast_nullable_to_non_nullable
              as List<AdaptiveFormat>,
      availableContainers: null == availableContainers
          ? _self.availableContainers
          : availableContainers // ignore: cast_nullable_to_non_nullable
              as List<DownloadContainer>,
      audioTracks: null == audioTracks
          ? _self.audioTracks
          : audioTracks // ignore: cast_nullable_to_non_nullable
              as List<AudioTrack>,
      captions: null == captions
          ? _self.captions
          : captions // ignore: cast_nullable_to_non_nullable
              as List<Caption>,
      container: freezed == container
          ? _self.container
          : container // ignore: cast_nullable_to_non_nullable
              as DownloadContainer?,
      audioTrackId: freezed == audioTrackId
          ? _self.audioTrackId
          : audioTrackId // ignore: cast_nullable_to_non_nullable
              as String?,
      captionLabel: freezed == captionLabel
          ? _self.captionLabel
          : captionLabel // ignore: cast_nullable_to_non_nullable
              as String?,
      quality: null == quality
          ? _self.quality
          : quality // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class _DownloadModalSheetState implements DownloadModalSheetState {
  const _DownloadModalSheetState(
      {this.audioOnly = false,
      this.loading = false,
      this.failed = false,
      this.audioTrackDiscoveryFailed = false,
      final List<AdaptiveFormat> availableQualities = const [],
      final List<DownloadContainer> availableContainers = const [],
      final List<AudioTrack> audioTracks = const [],
      final List<Caption> captions = const [],
      this.container,
      this.audioTrackId,
      this.captionLabel,
      this.quality = '720p'})
      : _availableQualities = availableQualities,
        _availableContainers = availableContainers,
        _audioTracks = audioTracks,
        _captions = captions;

  @override
  @JsonKey()
  final bool audioOnly;
  @override
  @JsonKey()
  final bool loading;
  @override
  @JsonKey()
  final bool failed;
  @override
  @JsonKey()
  final bool audioTrackDiscoveryFailed;
  final List<AdaptiveFormat> _availableQualities;
  @override
  @JsonKey()
  List<AdaptiveFormat> get availableQualities {
    if (_availableQualities is EqualUnmodifiableListView)
      return _availableQualities;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_availableQualities);
  }

  final List<DownloadContainer> _availableContainers;
  @override
  @JsonKey()
  List<DownloadContainer> get availableContainers {
    if (_availableContainers is EqualUnmodifiableListView)
      return _availableContainers;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_availableContainers);
  }

  final List<AudioTrack> _audioTracks;
  @override
  @JsonKey()
  List<AudioTrack> get audioTracks {
    if (_audioTracks is EqualUnmodifiableListView) return _audioTracks;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_audioTracks);
  }

  final List<Caption> _captions;
  @override
  @JsonKey()
  List<Caption> get captions {
    if (_captions is EqualUnmodifiableListView) return _captions;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_captions);
  }

  @override
  final DownloadContainer? container;
  @override
  final String? audioTrackId;
  @override
  final String? captionLabel;
  @override
  @JsonKey()
  final String quality;

  /// Create a copy of DownloadModalSheetState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$DownloadModalSheetStateCopyWith<_DownloadModalSheetState> get copyWith =>
      __$DownloadModalSheetStateCopyWithImpl<_DownloadModalSheetState>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _DownloadModalSheetState &&
            (identical(other.audioOnly, audioOnly) ||
                other.audioOnly == audioOnly) &&
            (identical(other.loading, loading) || other.loading == loading) &&
            (identical(other.failed, failed) || other.failed == failed) &&
            (identical(other.audioTrackDiscoveryFailed,
                    audioTrackDiscoveryFailed) ||
                other.audioTrackDiscoveryFailed == audioTrackDiscoveryFailed) &&
            const DeepCollectionEquality()
                .equals(other._availableQualities, _availableQualities) &&
            const DeepCollectionEquality()
                .equals(other._availableContainers, _availableContainers) &&
            const DeepCollectionEquality()
                .equals(other._audioTracks, _audioTracks) &&
            const DeepCollectionEquality().equals(other._captions, _captions) &&
            (identical(other.container, container) ||
                other.container == container) &&
            (identical(other.audioTrackId, audioTrackId) ||
                other.audioTrackId == audioTrackId) &&
            (identical(other.captionLabel, captionLabel) ||
                other.captionLabel == captionLabel) &&
            (identical(other.quality, quality) || other.quality == quality));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      audioOnly,
      loading,
      failed,
      audioTrackDiscoveryFailed,
      const DeepCollectionEquality().hash(_availableQualities),
      const DeepCollectionEquality().hash(_availableContainers),
      const DeepCollectionEquality().hash(_audioTracks),
      const DeepCollectionEquality().hash(_captions),
      container,
      audioTrackId,
      captionLabel,
      quality);

  @override
  String toString() {
    return 'DownloadModalSheetState(audioOnly: $audioOnly, loading: $loading, failed: $failed, audioTrackDiscoveryFailed: $audioTrackDiscoveryFailed, availableQualities: $availableQualities, availableContainers: $availableContainers, audioTracks: $audioTracks, captions: $captions, container: $container, audioTrackId: $audioTrackId, captionLabel: $captionLabel, quality: $quality)';
  }
}

/// @nodoc
abstract mixin class _$DownloadModalSheetStateCopyWith<$Res>
    implements $DownloadModalSheetStateCopyWith<$Res> {
  factory _$DownloadModalSheetStateCopyWith(_DownloadModalSheetState value,
          $Res Function(_DownloadModalSheetState) _then) =
      __$DownloadModalSheetStateCopyWithImpl;
  @override
  @useResult
  $Res call(
      {bool audioOnly,
      bool loading,
      bool failed,
      bool audioTrackDiscoveryFailed,
      List<AdaptiveFormat> availableQualities,
      List<DownloadContainer> availableContainers,
      List<AudioTrack> audioTracks,
      List<Caption> captions,
      DownloadContainer? container,
      String? audioTrackId,
      String? captionLabel,
      String quality});
}

/// @nodoc
class __$DownloadModalSheetStateCopyWithImpl<$Res>
    implements _$DownloadModalSheetStateCopyWith<$Res> {
  __$DownloadModalSheetStateCopyWithImpl(this._self, this._then);

  final _DownloadModalSheetState _self;
  final $Res Function(_DownloadModalSheetState) _then;

  /// Create a copy of DownloadModalSheetState
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? audioOnly = null,
    Object? loading = null,
    Object? failed = null,
    Object? audioTrackDiscoveryFailed = null,
    Object? availableQualities = null,
    Object? availableContainers = null,
    Object? audioTracks = null,
    Object? captions = null,
    Object? container = freezed,
    Object? audioTrackId = freezed,
    Object? captionLabel = freezed,
    Object? quality = null,
  }) {
    return _then(_DownloadModalSheetState(
      audioOnly: null == audioOnly
          ? _self.audioOnly
          : audioOnly // ignore: cast_nullable_to_non_nullable
              as bool,
      loading: null == loading
          ? _self.loading
          : loading // ignore: cast_nullable_to_non_nullable
              as bool,
      failed: null == failed
          ? _self.failed
          : failed // ignore: cast_nullable_to_non_nullable
              as bool,
      audioTrackDiscoveryFailed: null == audioTrackDiscoveryFailed
          ? _self.audioTrackDiscoveryFailed
          : audioTrackDiscoveryFailed // ignore: cast_nullable_to_non_nullable
              as bool,
      availableQualities: null == availableQualities
          ? _self._availableQualities
          : availableQualities // ignore: cast_nullable_to_non_nullable
              as List<AdaptiveFormat>,
      availableContainers: null == availableContainers
          ? _self._availableContainers
          : availableContainers // ignore: cast_nullable_to_non_nullable
              as List<DownloadContainer>,
      audioTracks: null == audioTracks
          ? _self._audioTracks
          : audioTracks // ignore: cast_nullable_to_non_nullable
              as List<AudioTrack>,
      captions: null == captions
          ? _self._captions
          : captions // ignore: cast_nullable_to_non_nullable
              as List<Caption>,
      container: freezed == container
          ? _self.container
          : container // ignore: cast_nullable_to_non_nullable
              as DownloadContainer?,
      audioTrackId: freezed == audioTrackId
          ? _self.audioTrackId
          : audioTrackId // ignore: cast_nullable_to_non_nullable
              as String?,
      captionLabel: freezed == captionLabel
          ? _self.captionLabel
          : captionLabel // ignore: cast_nullable_to_non_nullable
              as String?,
      quality: null == quality
          ? _self.quality
          : quality // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

// dart format on
